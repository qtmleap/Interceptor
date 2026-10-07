# The secret-free verify job accepts a push only as one new same-repository PR merge.
# GitHub API and Git are injected fakes; no network and no real repository are touched.
require_relative "test_helper"
require_relative "../lib/merge_verifier"

REPO = ReleaseConfig::REPOSITORY
WORKFLOW_REF = ReleaseConfig::WORKFLOW

class FakeApi
  attr_reader :requests

  def initialize(responses)
    @responses = responses
    @requests = []
  end

  def get(path)
    @requests << path
    value = @responses.fetch(path) { raise MergeVerifier::Error, "unexpected API path #{path}" }
    value.respond_to?(:call) ? value.call : value
  end
end

class FakeGit
  def initialize(table)
    @table = table
  end

  def call(*args)
    @table.fetch(args) { raise MergeVerifier::Error, "unexpected git #{args.inspect}" }
  end
end

def run_record(path:, id:, suite:, number: 1, attempt: 1, status: "completed", conclusion: "success", head: HEAD, event: "pull_request", branch: "codex/feature")
  {
    "id" => id, "path" => path, "event" => event, "head_sha" => head, "head_branch" => branch,
    "run_number" => number, "run_attempt" => attempt, "status" => status, "conclusion" => conclusion,
    "check_suite_id" => suite, "pull_requests" => [],
    "head_repository" => { "full_name" => REPO }
  }
end

def check_record(name, suite:, id:, status: "completed", conclusion: "success", head: HEAD, app: "github-actions")
  {
    "id" => id, "name" => name, "head_sha" => head, "status" => status, "conclusion" => conclusion,
    "app" => { "slug" => app }, "check_suite" => { "id" => suite }, "pull_requests" => []
  }
end

# One trusted run (suite 1000 + index) per required workflow path, one successful check per name.
def scenario(branch: "develop")
  runs = []
  checks = []
  ReleaseConfig::REQUIRED.each_with_index do |(path, names), index|
    runs << run_record(path: path, id: 100 + index, suite: 1000 + index, number: 5)
    names.each_with_index { |name, i| checks << check_record(name, suite: 1000 + index, id: 200 + index * 50 + i) }
  end
  pull = {
    "number" => 7, "merged" => true, "merge_commit_sha" => MERGE, "state" => "closed",
    "base" => { "ref" => branch, "repo" => { "full_name" => REPO } },
    "head" => { "sha" => HEAD, "ref" => "codex/feature", "repo" => { "full_name" => REPO } }
  }
  {
    branch: branch, runs: runs, checks: checks, pull: pull, pulls: [{ "number" => 7 }], tip: MERGE,
    # Two parents: the previous tip (first) and the PR head (second).
    parents: "#{MERGE} #{BEFORE} #{HEAD}\n", changed: "Sources/App.swift\0",
    env: {
      "GITHUB_ACTIONS" => "true", "RUNNER_ENVIRONMENT" => "self-hosted", "GITHUB_EVENT_NAME" => "push",
      "GITHUB_REPOSITORY" => REPO, "GITHUB_REF" => "refs/heads/#{branch}",
      "GITHUB_WORKFLOW_REF" => "#{REPO}/#{WORKFLOW_REF}@refs/heads/#{branch}",
      "GITHUB_RUN_ATTEMPT" => "1", "GITHUB_SHA" => MERGE
    },
    event: {
      "ref" => "refs/heads/#{branch}", "before" => BEFORE, "after" => MERGE,
      "created" => false, "deleted" => false, "forced" => false, "repository" => { "full_name" => REPO }
    }
  }
end

def responses(s)
  {
    "repos/#{REPO}/commits/#{MERGE}/pulls?per_page=100" => s[:pulls],
    "repos/#{REPO}/pulls/7" => s[:pull],
    "repos/#{REPO}/branches/#{s[:branch]}" => { "commit" => { "sha" => s[:tip] } },
    "repos/#{REPO}/actions/runs?head_sha=#{s[:pull].dig('head', 'sha')}&per_page=100&page=1" => { "workflow_runs" => s[:runs] },
    "repos/#{REPO}/commits/#{s[:pull].dig('head', 'sha')}/check-runs?per_page=100&filter=latest&page=1" => { "check_runs" => s[:checks] }
  }
end

def git_for(s)
  FakeGit.new(
    ["rev-list", "--parents", "-n", "1", MERGE] => s[:parents],
    ["diff", "--name-only", "-z", "#{MERGE}^1", MERGE, "--"] => s[:changed]
  )
end

def build(s, api: nil, attempts: 2)
  MergeVerifier.new(env: s[:env], event: s[:event], api: api || FakeApi.new(responses(s)), git: git_for(s), sleeper: ->(_) {}, attempts: attempts)
end

def rejects(name, branches: %w[develop master])
  branches.each do |branch|
    check "#{branch} rejects #{name}" do
      s = scenario(branch: branch)
      yield s
      error = error_of(MergeVerifier::Error, DeploymentPolicy::Error) { build(s).call }
      assert error, "unsafe merge was accepted"
    end
  end
end

check "required checks are configured for this repository" do
  assert !ReleaseConfig::REQUIRED.empty? && ReleaseConfig::REQUIRED.values.none?(&:empty?)
  assert ReleaseConfig::REQUIRED.keys.all? { |path| path.start_with?(".github/workflows/") }
  assert MergeVerifier::WORKFLOW == ".github/workflows/testflight.yaml"
end

%w[develop master].each do |branch|
  check "#{branch} accepts a two-parent merge whose second parent is the PR head" do
    assert build(scenario(branch: branch)).call == { pr_number: 7, sha: MERGE }
  end
end

check "a squash merge whose only parent is the previous tip is accepted" do
  s = scenario
  s[:parents] = "#{MERGE} #{BEFORE}\n"
  assert build(s).call[:sha] == MERGE
end

# Head-equals-merge: the "PR head" is the pushed commit itself, i.e. a direct push or fast-forward.
# The PR's trusted runs and checks are moved to the merge commit too, so the only remaining reason
# to refuse is the head-equals-merge rule itself (otherwise these would pass for the wrong reason).
def head_is_merge(s)
  s[:pull]["head"]["sha"] = MERGE
  s[:runs].each { |run| run["head_sha"] = MERGE }
  s[:checks].each { |entry| entry["head_sha"] = MERGE }
end

check "the head-equals-merge fixtures are otherwise acceptable" do
  s = scenario
  head_is_merge(s)
  s[:parents] = "#{MERGE} #{BEFORE}\n"
  s[:env]["GITHUB_SHA"] = MERGE
  verifier = build(s)
  verifier.send(:verify_checks, REPO, s[:pull])
end
rejects("a PR head equal to the merge commit (squash shape)") do |s|
  head_is_merge(s)
  s[:parents] = "#{MERGE} #{BEFORE}\n"
end
rejects("a PR head equal to the merge commit even with two parents") do |s|
  head_is_merge(s)
  s[:parents] = "#{MERGE} #{BEFORE} #{MERGE}\n"
end

rejects("a pull_request event") { |s| s[:env]["GITHUB_EVENT_NAME"] = "pull_request" }
rejects("a manual dispatch") { |s| s[:env]["GITHUB_EVENT_NAME"] = "workflow_dispatch" }
rejects("a schedule") { |s| s[:env]["GITHUB_EVENT_NAME"] = "schedule" }
rejects("a hosted runner") { |s| s[:env]["RUNNER_ENVIRONMENT"] = "github-hosted" }
rejects("a tag ref") { |s| s[:env]["GITHUB_REF"] = "refs/tags/v1"; s[:event]["ref"] = "refs/tags/v1" }
rejects("a feature branch") { |s| s[:env]["GITHUB_REF"] = "refs/heads/feature"; s[:event]["ref"] = "refs/heads/feature" }
rejects("a re-run") { |s| s[:env]["GITHUB_RUN_ATTEMPT"] = "2" }
rejects("another repository") { |s| s[:env]["GITHUB_REPOSITORY"] = "other/#{ReleaseConfig::APP_NAME}" }
rejects("another workflow ref") { |s| s[:env]["GITHUB_WORKFLOW_REF"] = s[:env]["GITHUB_WORKFLOW_REF"].sub("testflight", "integration") }
rejects("another event repository") { |s| s[:event]["repository"]["full_name"] = "other/x" }
rejects("branch creation") { |s| s[:event]["created"] = true }
rejects("branch deletion") { |s| s[:event]["deleted"] = true }
rejects("a forced push") { |s| s[:event]["forced"] = true }
rejects("a missing forced flag") { |s| s[:event].delete("forced") }
rejects("a zero before") { |s| s[:event]["before"] = "0" * 40 }
rejects("an after that differs from GITHUB_SHA") { |s| s[:event]["after"] = OTHER }
rejects("a malformed event") { |s| s[:event] = [] }
rejects("a first parent that is not before") { |s| s[:parents] = "#{MERGE} #{OTHER} #{HEAD}\n" }
rejects("a root commit") { |s| s[:parents] = "#{MERGE}\n" }
rejects("an octopus merge") { |s| s[:parents] = "#{MERGE} #{BEFORE} #{HEAD} #{OTHER}\n" }
rejects("a merge whose second parent is not the PR head") { |s| s[:parents] = "#{MERGE} #{BEFORE} #{OTHER}\n" }
rejects("a record-only change") { |s| s[:changed] = "fastlane/testflight/last_shipped.json\0" }
rejects("an empty change") { |s| s[:changed] = "" }

rejects("a push that no PR produced") { |s| s[:pulls] = [] }
rejects("an unmerged PR") { |s| s[:pull]["merged"] = false }
rejects("a merge SHA that differs") { |s| s[:pull]["merge_commit_sha"] = OTHER }
rejects("a PR into another base") { |s| s[:pull]["base"]["ref"] = s[:branch] == "develop" ? "master" : "develop" }
rejects("a fork PR") { |s| s[:pull]["head"]["repo"]["full_name"] = "other/x" }
rejects("a deleted fork") { |s| s[:pull]["head"]["repo"] = nil }
rejects("an obsolete merge") { |s| s[:tip] = OTHER }

check "two matching PRs are ambiguous" do
  s = scenario
  s[:pulls] = [{ "number" => 7 }, { "number" => 8 }]
  api = FakeApi.new(responses(s).merge("repos/#{REPO}/pulls/8" => s[:pull].merge("number" => 8)))
  error = error_of(MergeVerifier::Error) { build(s, api: api, attempts: 1).call }
  assert error && error.message.include?("Several"), error.inspect
end

check "a late PR index is retried a bounded number of times" do
  s = scenario
  calls = 0
  table = responses(s).merge("repos/#{REPO}/commits/#{MERGE}/pulls?per_page=100" => -> { (calls += 1) < 2 ? [] : s[:pulls] })
  sleeps = []
  verifier = MergeVerifier.new(env: s[:env], event: s[:event], api: FakeApi.new(table), git: git_for(s), sleeper: ->(n) { sleeps << n }, attempts: 3)
  assert verifier.call[:sha] == MERGE && calls == 2 && sleeps.length == 1, "calls=#{calls} sleeps=#{sleeps.inspect}"
end

# Required checks: every configured workflow path and job name must have succeeded in a trusted run.
ReleaseConfig::REQUIRED.each_value do |names|
  names.each do |name|
    rejects("a missing #{name} check", branches: ["develop"]) { |s| s[:checks].reject! { |c| c["name"] == name } }
    rejects("a failed #{name} check", branches: ["develop"]) { |s| s[:checks].find { |c| c["name"] == name }["conclusion"] = "failure" }
    rejects("a skipped #{name} check", branches: ["develop"]) { |s| s[:checks].find { |c| c["name"] == name }["conclusion"] = "skipped" }
    rejects("a pending #{name} check", branches: ["develop"]) { |s| c = s[:checks].find { |x| x["name"] == name }; c["status"] = "in_progress"; c["conclusion"] = nil }
    rejects("a #{name} check from an untrusted suite", branches: ["develop"]) { |s| s[:checks].find { |c| c["name"] == name }["check_suite"]["id"] = 9999 }
  end
end
rejects("a check from another app", branches: ["develop"]) { |s| s[:checks].each { |c| c["app"]["slug"] = "other-app" } }
%w[path event head_sha head_branch].each do |field|
  rejects("a run with a different #{field}", branches: ["develop"]) { |s| s[:runs][0][field] = "other" }
end
rejects("a run from another repository", branches: ["develop"]) { |s| s[:runs][0]["head_repository"]["full_name"] = "other/x" }
rejects("a missing workflow run", branches: ["develop"]) { |s| s[:runs].shift }
rejects("a pending latest run", branches: ["develop"]) { |s| s[:runs][0]["status"] = "in_progress"; s[:runs][0]["conclusion"] = nil }
rejects("a run from a manual dispatch", branches: ["develop"]) { |s| s[:runs][0]["event"] = "workflow_dispatch" }

check "an empty required map is refused" do
  s = scenario
  required = MergeVerifier::REQUIRED.dup
  MergeVerifier.send(:remove_const, :REQUIRED)
  MergeVerifier.const_set(:REQUIRED, {}.freeze)
  begin
    error = error_of(MergeVerifier::Error) { build(s).call }
    assert error && error.message.include?("No required checks"), error.inspect
  ensure
    MergeVerifier.send(:remove_const, :REQUIRED)
    MergeVerifier.const_set(:REQUIRED, required)
  end
end

check "a latest failed rerun supersedes an older success" do
  s = scenario
  path, names = ReleaseConfig::REQUIRED.first
  s[:runs] << run_record(path: path, id: 910, suite: 9100, number: 6, conclusion: "failure")
  s[:checks] << check_record(names.first, suite: 9100, id: 9101, conclusion: "failure")
  assert error_of(MergeVerifier::Error) { build(s).call }, "an older success hid a newer failure"
end

check "a latest successful rerun supersedes an older failure" do
  s = scenario
  path, names = ReleaseConfig::REQUIRED.first
  s[:runs] << run_record(path: path, id: 900, suite: 9000, number: 4, conclusion: "failure")
  s[:checks] << check_record(names.first, suite: 9000, id: 9001, conclusion: "failure")
  assert build(s).call[:sha] == MERGE
end

check "a failed second attempt of the same run blocks earlier successful checks" do
  s = scenario
  s[:runs][0]["run_attempt"] = 2
  s[:runs][0]["conclusion"] = "failure"
  assert error_of(MergeVerifier::Error) { build(s).call }
end

check "trusted workflow runs and checks on the second API page are accepted" do
  s = scenario
  table = responses(s)
  table["repos/#{REPO}/actions/runs?head_sha=#{HEAD}&per_page=100&page=1"] = {
    "workflow_runs" => Array.new(100) { |i| run_record(path: ".github/workflows/other.yaml", id: 500 + i, suite: 5000 + i) }
  }
  table["repos/#{REPO}/actions/runs?head_sha=#{HEAD}&per_page=100&page=2"] = { "workflow_runs" => s[:runs] }
  table["repos/#{REPO}/commits/#{HEAD}/check-runs?per_page=100&filter=latest&page=1"] = {
    "check_runs" => Array.new(100) { |i| check_record("Other #{i}", suite: 9000, id: 900 + i) }
  }
  table["repos/#{REPO}/commits/#{HEAD}/check-runs?per_page=100&filter=latest&page=2"] = { "check_runs" => s[:checks] }
  api = FakeApi.new(table)
  assert build(s, api: api, attempts: 1).call == { pr_number: 7, sha: MERGE }
  assert api.requests.any? { |path| path.include?("&page=2") }
end

check "pagination is bounded" do
  s = scenario
  table = responses(s)
  (1..40).each do |page|
    table["repos/#{REPO}/actions/runs?head_sha=#{HEAD}&per_page=100&page=#{page}"] = {
      "workflow_runs" => Array.new(100) { |i| run_record(path: ".github/workflows/x.yaml", id: page * 1000 + i, suite: i, number: i) }
    }
  end
  api = FakeApi.new(table)
  assert error_of(MergeVerifier::Error) { build(s, api: api, attempts: 1).call }, "unbounded pagination"
  assert api.requests.length <= 2 + MergeVerifier::MAX_PAGES, "too many requests: #{api.requests.length}"
end

check "an API error response is a refusal, not a pass" do
  s = scenario
  table = responses(s)
  table["repos/#{REPO}/pulls/7"] = -> { raise MergeVerifier::Error, "GitHub API returned 500." }
  assert error_of(MergeVerifier::Error) { build(s, api: FakeApi.new(table), attempts: 1).call }
end

check "a malformed API payload is a refusal" do
  s = scenario
  table = responses(s)
  table["repos/#{REPO}/actions/runs?head_sha=#{HEAD}&per_page=100&page=1"] = { "unexpected" => [] }
  assert error_of(MergeVerifier::Error, KeyError) { build(s, api: FakeApi.new(table), attempts: 1).call }
end

check "the output file receives only the verified SHA and PR number" do
  Dir.mktmpdir do |dir|
    path = File.join(dir, "out")
    MergeVerifier.write_output(path, pr_number: 7, sha: MERGE)
    assert File.read(path) == "pr_number=7\nsha=#{MERGE}\n", File.read(path)
  end
end

check "the verifier needs only a read token and refuses an empty one" do
  assert error_of(MergeVerifier::Error) { MergeVerifier::Api.new(token: "") }
  assert error_of(MergeVerifier::Error) { MergeVerifier::Api.new(token: nil) }
end

check "the verifier source references no credential variables" do
  source = File.read(File.expand_path("../lib/merge_verifier.rb", __dir__))
  assert !source.match?(/TESTFLIGHT_|MATCH_|ASC_|QUANTUMLEAP/), "the verifier must stay secret-free"
end

finish
