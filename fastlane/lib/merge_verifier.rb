# Verify job only: runs on a secret-free Linux runner and confirms that this push is a genuine,
# new, same-repository PR merge into develop or master. It hands only the SHA and PR number to the
# protected release job. Pure Ruby; the GitHub API and Git are injectable (see test/merge_verifier_test.rb).
require "json"
require "net/http"
require "open3"
require_relative "deployment_policy"

class MergeVerifier
  class Error < StandardError; end

  REPOSITORY = DeploymentPolicy::REPOSITORY
  BRANCHES = DeploymentPolicy::BRANCHES
  SHA_PATTERN = DeploymentPolicy::SHA_PATTERN
  WORKFLOW = DeploymentPolicy::WORKFLOW
  PER_PAGE = 100
  # Bounds pagination even if the API keeps returning full pages.
  MAX_PAGES = 10

  # Trusted pull_request workflow runs and the exact job names that must have succeeded on the PR head.
  # Identified by workflow path, event, head SHA, head branch and head repository, never by name alone.
  REQUIRED = ReleaseConfig::REQUIRED

  class Api
    def initialize(token:)
      @token = token.to_s
      raise Error, "GITHUB_TOKEN is not set." if @token.empty?
    end

    def get(path)
      uri = URI("https://api.github.com/#{path}")
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@token}"
      request["Accept"] = "application/vnd.github+json"
      request["X-GitHub-Api-Version"] = "2022-11-28"
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 30) { |http| http.request(request) }
      raise Error, "GitHub API #{path.split('?').first} returned #{response.code}." unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    end
  end

  class Git
    def initialize(directory)
      @directory = directory
    end

    def call(*args)
      out, status = Open3.capture2("git", "-C", @directory, *args, err: File::NULL)
      raise Error, "git #{args.first} failed." unless status.success?

      out
    end
  end

  def self.write_output(path, pr_number:, sha:)
    File.open(path, "a") { |file| file.write("pr_number=#{pr_number}\nsha=#{sha}\n") }
  end

  def initialize(env:, event:, api:, git:, sleeper: ->(seconds) { sleep(seconds) }, attempts: 6, delay: 10)
    @env = env
    @event = event
    @api = api
    @git = git
    @sleeper = sleeper
    @attempts = attempts
    @delay = delay
  end

  def call
    sha = @env.fetch("GITHUB_SHA", "")
    repo = @env.fetch("GITHUB_REPOSITORY", "")
    branch = @env.fetch("GITHUB_REF", "").delete_prefix("refs/heads/")
    verify_push(sha, repo, branch)
    parents = lineage(sha)
    pull = find_pull(repo, sha, branch)
    verify_second_parent(parents, pull)
    verify_checks(repo, pull)
    # Verification takes time; make sure no newer merge landed meanwhile.
    tip = @api.get("repos/#{repo}/branches/#{branch}").dig("commit", "sha")
    raise Error, "#{branch} has advanced. The newer merge takes precedence." unless tip == sha

    { pr_number: pull.fetch("number"), sha: sha }
  end

  private

  def verify_push(sha, repo, branch)
    unless @env["GITHUB_ACTIONS"] == "true" && @env["RUNNER_ENVIRONMENT"] == "self-hosted"
      raise Error, "Runs only in GitHub CI on a self-hosted runner."
    end
    raise Error, "Not a push event." unless @env["GITHUB_EVENT_NAME"] == "push"

    ref = @env["GITHUB_REF"]
    raise Error, "Branch is not releasable: #{branch}" unless ref == "refs/heads/#{branch}" && BRANCHES.include?(branch)
    raise Error, "CI reruns do not release." unless @env["GITHUB_RUN_ATTEMPT"] == "1"
    raise Error, "Repository mismatch." unless repo == REPOSITORY
    raise Error, "Workflow mismatch." unless @env["GITHUB_WORKFLOW_REF"] == "#{repo}/#{WORKFLOW}@#{ref}"
    raise Error, "Event ref differs from GITHUB_REF." unless @event.is_a?(Hash) && @event["ref"] == ref
    raise Error, "Event repository mismatch." unless @event.dig("repository", "full_name") == repo
    raise Error, "Branch creation is not a merge." unless @event["created"] == false
    raise Error, "Branch deletion is not a merge." unless @event["deleted"] == false
    raise Error, "Force pushes do not release." unless @event["forced"] == false
    raise Error, "GITHUB_SHA is invalid." unless sha.match?(SHA_PATTERN)
    raise Error, "Push after differs from GITHUB_SHA." unless @event["after"] == sha

    before = @event["before"]
    raise Error, "Push before is invalid." unless before.is_a?(String) && before.match?(SHA_PATTERN)
    raise Error, "Push before is all zeros." if before.match?(/\A0+\z/)
  rescue TypeError, NoMethodError
    raise Error, "The push event is malformed."
  end

  # Checks the parents so a multi-commit push is not released as a single merge, and rejects a
  # push whose head equals the merge commit (a direct push or fast-forward, not a PR merge).
  # A record-only change or an empty merge is not released.
  def lineage(sha)
    fields = @git.call("rev-list", "--parents", "-n", "1", sha).split
    raise Error, "Cannot read the merge commit's parents." unless fields.first == sha && fields.drop(1).all? { |p| p.match?(SHA_PATTERN) }

    parents = fields.drop(1)
    raise Error, "A commit without parents is not released." if parents.empty? || parents.length > 2
    raise Error, "The first parent is not the push's before." unless parents.first == @event["before"]

    paths = @git.call("diff", "--name-only", "-z", "#{sha}^1", sha, "--").split("\0")
    unless paths.any? { |path| path != DeploymentPolicy::SHIPPED_RECORD }
      raise Error, "A record-only change or an empty merge is not released."
    end
    parents
  end

  # A merge commit's second parent is the PR head. A squash has one parent and its head is checked
  # through the PR record. A head equal to the merge commit is a direct push, never a PR merge.
  def verify_second_parent(parents, pull)
    head = pull.dig("head", "sha")
    raise Error, "The PR head equals the merge commit (direct push)." if head == @env["GITHUB_SHA"]
    return if parents.length == 1
    raise Error, "The second parent is not the PR head." unless parents[1] == head
  end

  # commits/:sha/pulls can lag, so poll a bounded number of times.
  def find_pull(repo, sha, branch)
    matches = []
    @attempts.times do |index|
      listed = @api.get("repos/#{repo}/commits/#{sha}/pulls?per_page=#{PER_PAGE}")
      matches = listed.map { |entry| entry.fetch("number") }.uniq.filter_map do |number|
        pull = @api.get("repos/#{repo}/pulls/#{number}")
        pull if acceptable_pull?(pull, repo, sha, branch)
      end
      break unless matches.empty?

      @sleeper.call(@delay) if index < @attempts - 1
    end
    raise Error, "No merged PR produced #{sha}." if matches.empty?
    raise Error, "Several PRs claim #{sha}; cannot identify the merge." unless matches.length == 1

    matches.first
  end

  def acceptable_pull?(pull, repo, sha, branch)
    pull["merged"] == true && pull["merge_commit_sha"] == sha && pull.dig("base", "ref") == branch &&
      pull.dig("base", "repo", "full_name") == repo && pull.dig("head", "repo", "full_name") == repo &&
      pull.dig("head", "sha").to_s.match?(SHA_PATTERN) && !pull.dig("head", "ref").to_s.empty?
  end

  # After a merge the PR arrays are empty, so trust is derived from the run's path, event, head SHA,
  # head branch and head repository.
  def verify_checks(repo, pull)
    head = pull.dig("head", "sha")
    runs = paginate("repos/#{repo}/actions/runs?head_sha=#{head}&per_page=#{PER_PAGE}", "workflow_runs")
    checks = paginate("repos/#{repo}/commits/#{head}/check-runs?per_page=#{PER_PAGE}&filter=latest", "check_runs")
    problems = []
    raise Error, "No required checks are configured." if REQUIRED.empty? || REQUIRED.values.any?(&:empty?)

    REQUIRED.each do |path, names|
      trusted = runs.select do |run|
        run["path"] == path && run["event"] == "pull_request" && run["head_sha"] == head &&
          run["head_branch"] == pull.dig("head", "ref") && run.dig("head_repository", "full_name") == repo
      end
      latest = trusted.max_by { |run| [run["run_number"].to_i, run["run_attempt"].to_i, run["id"].to_i] }
      unless latest && latest["status"] == "completed" && latest["conclusion"] == "success"
        problems << path
        next
      end
      names.each do |name|
        candidates = checks.select do |check|
          check["name"] == name && check.dig("app", "slug") == "github-actions" && check["head_sha"] == head &&
            check.dig("check_suite", "id") == latest["check_suite_id"]
        end
        check = candidates.max_by { |entry| entry["id"].to_i }
        problems << name unless check && check["status"] == "completed" && check["conclusion"] == "success"
      end
    end
    raise Error, "Required checks did not succeed on the PR head: #{problems.join(', ')}" unless problems.empty?
  end

  def paginate(path, key)
    items = []
    (1..MAX_PAGES).each do |page|
      batch = @api.get("#{path}&page=#{page}").fetch(key)
      items.concat(batch)
      return items if batch.length < PER_PAGE
    end
    raise Error, "#{key} exceeds #{MAX_PAGES * PER_PAGE} entries and cannot be verified."
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    result = MergeVerifier.new(
      env: ENV.to_h,
      event: JSON.parse(File.read(ENV.fetch("GITHUB_EVENT_PATH"))),
      api: MergeVerifier::Api.new(token: ENV["GITHUB_TOKEN"]),
      git: MergeVerifier::Git.new(Dir.pwd)
    ).call
    MergeVerifier.write_output(ENV.fetch("GITHUB_OUTPUT"), **result)
    puts "verified: PR ##{result[:pr_number]} -> #{result[:sha]}"
  rescue MergeVerifier::Error, DeploymentPolicy::Error, JSON::ParserError, KeyError, SystemCallError => error
    warn "::error::#{error.message}"
    exit 1
  end
end
