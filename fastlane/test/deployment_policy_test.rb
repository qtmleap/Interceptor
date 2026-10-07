# Release authorization: only the exact, verified CI merge may reach credentials and upload.
require_relative "test_helper"
require_relative "../lib/deployment_policy"

REPO = ReleaseConfig::REPOSITORY
SHA_VAR = DeploymentPolicy::VERIFIED_SHA
PR_VAR = DeploymentPolicy::VERIFIED_PR

def allowed_fixture(branch = "develop")
  {
    lane: :beta,
    env: {
      "GITHUB_ACTIONS" => "true", "RUNNER_ENVIRONMENT" => "self-hosted", "GITHUB_EVENT_NAME" => "push",
      "GITHUB_REPOSITORY" => REPO, "GITHUB_REF" => "refs/heads/#{branch}",
      "GITHUB_WORKFLOW_REF" => "#{REPO}/#{ReleaseConfig::WORKFLOW}@refs/heads/#{branch}",
      "GITHUB_RUN_ATTEMPT" => "1", "GITHUB_SHA" => MERGE, SHA_VAR => MERGE, PR_VAR => "7"
    },
    event: {
      "ref" => "refs/heads/#{branch}", "before" => BEFORE, "after" => MERGE,
      "created" => false, "deleted" => false, "forced" => false, "repository" => { "full_name" => REPO }
    },
    head_sha: MERGE, branch_sha: MERGE, dirty_count: 0, first_parent: BEFORE,
    changed_paths: ["Sources/App.swift"]
  }
end

%w[develop master].each do |branch|
  check "the exact current #{branch} merge from this repository is accepted" do
    assert DeploymentPolicy.validate!(**allowed_fixture(branch)) == MERGE
  end
end

other_branch = ->(ref) { ref.end_with?("develop") ? ref.sub("develop", "master") : ref.sub("master", "develop") }
cases = {
  "hosted runner" => ->(f) { f[:env]["RUNNER_ENVIRONMENT"] = "github-hosted" },
  "unknown runner" => ->(f) { f[:env]["RUNNER_ENVIRONMENT"] = nil },
  "local execution" => ->(f) { f[:env]["GITHUB_ACTIONS"] = nil },
  "manual dispatch" => ->(f) { f[:env]["GITHUB_EVENT_NAME"] = "workflow_dispatch" },
  "closed pull request event" => ->(f) { f[:env]["GITHUB_EVENT_NAME"] = "pull_request" },
  "tag push" => ->(f) { f[:env]["GITHUB_REF"] = "refs/tags/v0.1.0"; f[:event]["ref"] = "refs/tags/v0.1.0" },
  "mismatched event ref" => ->(f) { f[:event]["ref"] = other_branch.call(f[:event]["ref"]) },
  "mismatched ref" => ->(f) { f[:env]["GITHUB_REF"] = other_branch.call(f[:env]["GITHUB_REF"]) },
  "mismatched workflow branch" => ->(f) { f[:env]["GITHUB_WORKFLOW_REF"] = other_branch.call(f[:env]["GITHUB_WORKFLOW_REF"]) },
  "other workflow" => ->(f) { f[:env]["GITHUB_WORKFLOW_REF"] = f[:env]["GITHUB_WORKFLOW_REF"].sub("testflight", "ios-ci") },
  "unapproved branch" => lambda { |f|
    f[:event]["ref"] = f[:env]["GITHUB_REF"] = "refs/heads/feature"
    f[:env]["GITHUB_WORKFLOW_REF"] = "#{REPO}/#{ReleaseConfig::WORKFLOW}@refs/heads/feature"
  },
  "other environment repository" => ->(f) { f[:env]["GITHUB_REPOSITORY"] = "other/x" },
  "other event repository" => ->(f) { f[:event]["repository"]["full_name"] = "other/x" },
  "branch creation" => ->(f) { f[:event]["created"] = true },
  "branch deletion" => ->(f) { f[:event]["deleted"] = true },
  "forced push" => ->(f) { f[:event]["forced"] = true },
  "missing forced flag" => ->(f) { f[:event].delete("forced") },
  "zero before" => ->(f) { f[:event]["before"] = "0" * 40; f[:first_parent] = "0" * 40 },
  "invalid before" => ->(f) { f[:event]["before"] = "HEAD" },
  "event after differs" => ->(f) { f[:event]["after"] = OTHER },
  "revision expression" => ->(f) { f[:env]["GITHUB_SHA"] = "HEAD" },
  "missing verifier SHA" => ->(f) { f[:env].delete(SHA_VAR) },
  "other verifier SHA" => ->(f) { f[:env][SHA_VAR] = OTHER },
  "missing verifier PR" => ->(f) { f[:env].delete(PR_VAR) },
  "invalid verifier PR" => ->(f) { f[:env][PR_VAR] = "0" },
  "first parent differs from before" => ->(f) { f[:first_parent] = OTHER },
  "wrong checkout" => ->(f) { f[:head_sha] = OTHER },
  "second run attempt" => ->(f) { f[:env]["GITHUB_RUN_ATTEMPT"] = "2" },
  "missing run attempt" => ->(f) { f[:env]["GITHUB_RUN_ATTEMPT"] = nil },
  "obsolete merge" => ->(f) { f[:branch_sha] = OTHER },
  "dirty checkout" => ->(f) { f[:dirty_count] = 1 },
  "unknown checkout status" => ->(f) { f[:dirty_count] = nil },
  "record-only merge" => ->(f) { f[:changed_paths] = [DeploymentPolicy::SHIPPED_RECORD] },
  "empty diff" => ->(f) { f[:changed_paths] = [] },
  "unknown diff" => ->(f) { f[:changed_paths] = nil },
  "invalid diff paths" => ->(f) { f[:changed_paths] = [nil] },
  "malformed event repository" => ->(f) { f[:event]["repository"] = "invalid" },
  "malformed event" => ->(f) { f[:event] = [] },
  "App Store lane" => ->(f) { f[:lane] = :release }
}

def with_git_fixture(branch)
  Dir.mktmpdir do |dir|
    event_path = File.join(dir, "event.json")
    refs_path = File.join(dir, "refs.json")
    fixture = allowed_fixture(branch)
    File.write(event_path, JSON.generate(fixture[:event]))
    refs = { "develop" => OTHER, "master" => OTHER, branch => MERGE }
    File.write(refs_path, JSON.generate(refs))
    File.write(File.join(dir, "git"), <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"
      args = ARGV.drop(2)
      case args
      when ["rev-parse", "--verify", "HEAD^{commit}"] then puts #{MERGE.inspect}
      when ["rev-parse", "--verify", "#{MERGE}^1^{commit}"] then puts #{BEFORE.inspect}
      when ["status", "--porcelain", "-z", "--untracked-files=all"] then nil
      when ["diff", "--name-only", "-z", "#{MERGE}^1", #{MERGE.inspect}, "--"] then print "Sources/App.swift\\0"
      when ["ls-remote", "--exit-code", "origin", "refs/heads/develop"], ["ls-remote", "--exit-code", "origin", "refs/heads/master"]
        ref = args.last
        puts "\#{JSON.parse(File.read(#{refs_path.inspect})).fetch(ref.delete_prefix("refs/heads/"))}\\t\#{ref}"
      else abort "Unexpected Git query: \#{args.inspect}"
      end
    RUBY
    File.chmod(0o755, File.join(dir, "git"))
    env = fixture[:env].merge("GITHUB_EVENT_PATH" => event_path, "PATH" => "#{dir}:#{ENV.fetch('PATH')}")
    with_environment(env) { yield dir, refs_path, refs }
  end
end

%w[develop master].each do |branch|
  cases.each do |name, mutate|
    check "#{branch} rejects #{name}" do
      fixture = allowed_fixture(branch)
      mutate.call(fixture)
      assert error_of(DeploymentPolicy::Error) { DeploymentPolicy.validate!(**fixture) }, "unsafe deployment was accepted"
    end
  end

  check "#{branch} upload revalidation rejects a changed event or archive SHA" do
    with_git_fixture(branch) do |dir, _, _|
      sha = DeploymentPolicy.authorize!(lane: :beta, repo_root: dir)
      assert error_of(DeploymentPolicy::Error) { DeploymentPolicy.verify_current!(repo_root: dir, sha: OTHER) }
      other = branch == "develop" ? "master" : "develop"
      File.write(ENV.fetch("GITHUB_EVENT_PATH"), JSON.generate(allowed_fixture(other)[:event]))
      assert error_of(DeploymentPolicy::Error) { DeploymentPolicy.verify_current!(repo_root: dir, sha: sha) }
    end
  end

  ["#{MERGE}\trefs/heads/feature\n", "invalid\trefs/heads/#{branch}\n", "", "#{MERGE}\trefs/heads/#{branch}\n#{OTHER}\trefs/heads/master\n"].each do |output|
    check "#{branch} lookup rejects an invalid remote response #{output.inspect}" do
      policy = DeploymentPolicy.dup
      policy.define_singleton_method(:git_output) { |*_| output }
      assert error_of(DeploymentPolicy::Error) { policy.branch_sha("fixture", branch: branch) }
    end
  end

  check "#{branch} authorization and revalidation use its live tip, not the other branch" do
    with_git_fixture(branch) do |dir, refs_path, refs|
      sha = DeploymentPolicy.authorize!(lane: :beta, repo_root: dir)
      assert sha == MERGE
      DeploymentPolicy.verify_current!(repo_root: dir, sha: sha)
      refs[branch] = OTHER
      refs[branch == "develop" ? "master" : "develop"] = MERGE
      File.write(refs_path, JSON.generate(refs))
      assert error_of(DeploymentPolicy::Error) { DeploymentPolicy.authorize!(lane: :beta, repo_root: dir) }
      assert error_of(DeploymentPolicy::Error) { DeploymentPolicy.verify_current!(repo_root: dir, sha: sha) }
    end
  end
end

check "a merge containing code and the shipped record is accepted" do
  fixture = allowed_fixture
  fixture[:changed_paths] << DeploymentPolicy::SHIPPED_RECORD
  assert DeploymentPolicy.validate!(**fixture) == MERGE
end

check "a clean real git checkout reports exact HEAD and zero dirty entries; changes are counted" do
  Dir.mktmpdir do |dir|
    git = ->(*args) { system("git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", *args, out: File::NULL, err: File::NULL) or raise "git #{args.first}" }
    git.call("init", "-q")
    File.write(File.join(dir, "a.txt"), "1")
    git.call("add", ".")
    git.call("commit", "-q", "-m", "test(ci): add state fixture")
    head, dirty = DeploymentPolicy.git_state(dir)
    assert head.match?(DeploymentPolicy::SHA_PATTERN) && dirty == 0, [head, dirty].inspect
    File.write(File.join(dir, "new.txt"), "2")
    assert DeploymentPolicy.git_state(dir).last == 1, "untracked file not counted"
    assert error_of(DeploymentPolicy::Error) { DeploymentPolicy.git_state(File.join(dir, "missing")) } ||
           DeploymentPolicy.git_state(File.join(dir, "missing")).last.nil?, "unreadable state must fail closed"
  end
end

CREDENTIALS = %w[
  ASC_KEY_ID ASC_KEY_CONTENT APP_STORE_CONNECT_API_KEY_KEY MATCH_PASSWORD MATCH_GIT_TOKEN
  MATCH_GIT_BASIC_AUTHORIZATION MATCH_GIT_PRIVATE_KEY GITHUB_TOKEN GH_TOKEN MATCH_APP_CLIENT_ID MATCH_APP_PRIVATE_KEY
  TESTFLIGHT_ASC_KEY_CONTENT TESTFLIGHT_MATCH_PASSWORD TESTFLIGHT_MATCH_GIT_TOKEN TESTFLIGHT_QUANTUMLEAP_READ_TOKEN
  TESTFLIGHT_FIREBASE_CONFIG QUANTUMLEAP_READ_TOKEN GIT_ASKPASS GIT_CONFIG_PARAMETERS GIT_CONFIG_VALUE_0
  ACTIONS_RUNTIME_TOKEN FASTLANE_PASSWORD
].freeze

check "credential scrubbing removes every signing, upload, dependency and Git credential and restores them exactly" do
  env = CREDENTIALS.to_h { |name| [name, "value-#{name}"] }
  env["GITHUB_SHA"] = env["RUNNER_TEMP"] = env["MATCH_KEYCHAIN_NAME_KEEP"] = "keep"
  inside = nil
  DeploymentPolicy.without_credentials(env) { inside = env.dup }
  assert CREDENTIALS.none? { |name| inside.key?(name) }, "credential remained: #{(inside.keys & CREDENTIALS).inspect}"
  assert inside["GITHUB_SHA"] == "keep" && inside["RUNNER_TEMP"] == "keep", "non-secret variable removed"
  assert CREDENTIALS.all? { |name| env[name] == "value-#{name}" }, "values not restored"
  assert error_of(RuntimeError) { DeploymentPolicy.without_credentials(env) { raise "archive failed" } }
  assert CREDENTIALS.all? { |name| env[name] == "value-#{name}" }, "values not restored after an exception"
end

check "a child environment unsets every credential variable" do
  env = CREDENTIALS.to_h { |name| [name, "x"] }.merge("PATH" => "/bin")
  overrides = DeploymentPolicy.child_environment(env)
  assert CREDENTIALS.all? { |name| overrides.key?(name) && overrides[name].nil? } && !overrides.key?("PATH")
end

check "a real child process does not inherit scrubbed credentials" do
  env_before = ENV.to_h
  with_environment("TESTFLIGHT_MATCH_PASSWORD" => "secret-value", "MATCH_GIT_TOKEN" => "secret-value", "GITHUB_TOKEN" => "gh") do
    seen = DeploymentPolicy.without_credentials { IO.popen([RbConfig.ruby, "-e", 'print ENV.keys.grep(/TESTFLIGHT_|MATCH_|GITHUB_TOKEN/).join(",")']) { |io| io.read } }
    assert seen.empty?, "child saw #{seen}"
    assert ENV["TESTFLIGHT_MATCH_PASSWORD"] == "secret-value"
  end
  assert ENV.to_h == env_before
end

check "the authorization mask covers every registered value and skips blanks" do
  assert DeploymentPolicy.mask_lines("abc", "", nil, "def") == ["::add-mask::abc", "::add-mask::def"]
end

finish
