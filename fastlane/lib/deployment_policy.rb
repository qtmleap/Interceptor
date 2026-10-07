# Allows an iOS release only for the exact merge commit that CI verified, never for a
# working tree, another branch, a rerun or a local invocation. Pure Ruby (no fastlane).
require "json"
require "open3"
require_relative "release_config"
require_relative "git_state"

module DeploymentPolicy
  class Error < StandardError; end

  REPOSITORY = ReleaseConfig::REPOSITORY
  WORKFLOW = ReleaseConfig::WORKFLOW
  BRANCHES = %w[develop master].freeze
  SHIPPED_RECORD = "fastlane/testflight/last_shipped.json"
  SHA_PATTERN = /\A[0-9a-f]{40}\z/

  # Outputs of the secret-free verify job. A push alone does not prove a PR merge, so both are required.
  VERIFIED_SHA = ReleaseConfig::VERIFIED_SHA_ENV
  VERIFIED_PR = ReleaseConfig::VERIFIED_PR_ENV

  # Credentials that must never reach xcodebuild or any other build child process.
  SCRUBBED_EXACT = %w[
    GITHUB_TOKEN GH_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN RELEASE_SOURCE_READ_TOKEN
    GIT_ASKPASS SSH_ASKPASS GIT_SSH_COMMAND GIT_CONFIG_PARAMETERS
    FASTLANE_PASSWORD FASTLANE_SESSION FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD
    ACTIONS_RUNTIME_TOKEN ACTIONS_ID_TOKEN_REQUEST_TOKEN ACTIONS_ID_TOKEN_REQUEST_URL
  ].freeze
  SCRUBBED_PREFIXES = %w[
    ASC_ APP_STORE_CONNECT_API_KEY_ MATCH_ TESTFLIGHT_ QUANTUMLEAP_ GIT_CONFIG_
  ].freeze

  module_function

  def credential_name?(name)
    SCRUBBED_EXACT.include?(name) || SCRUBBED_PREFIXES.any? { |prefix| name.start_with?(prefix) }
  end

  # Removes credentials for the duration of the block and restores them exactly, even on error.
  # Variables that were absent stay absent.
  def without_credentials(env = ENV)
    saved = env.keys.select { |name| credential_name?(name) }.to_h { |name| [name, env[name]] }
    saved.each_key { |name| env.delete(name) }
    begin
      yield
    ensure
      saved.each { |name, value| env[name] = value }
    end
  end

  # Environment overrides for a spawned child: nil unsets the variable.
  def child_environment(env = ENV)
    env.keys.select { |name| credential_name?(name) }.to_h { |name| [name, nil] }
  end

  # Actions masks only the original value, so a derived Basic authorization is registered as well.
  def mask_lines(*values)
    values.map(&:to_s).reject(&:empty?).map { |value| "::add-mask::#{value}" }
  end

  def environment!(lane:, env:)
    unless lane.to_s == "beta"
      raise Error, "Only the CI beta lane may upload. App Store release is disabled."
    end
    unless env["GITHUB_ACTIONS"] == "true" && env["GITHUB_EVENT_NAME"] == "push"
      raise Error, "Uploads run only in GitHub CI for a push produced by a develop or master merge."
    end
    raise Error, "Uploads run only on a self-hosted CI runner." unless env["RUNNER_ENVIRONMENT"] == "self-hosted"

    branch = env["GITHUB_REF"].to_s.delete_prefix("refs/heads/")
    unless env["GITHUB_REPOSITORY"] == REPOSITORY && BRANCHES.include?(branch) &&
           env["GITHUB_REF"] == "refs/heads/#{branch}" &&
           env["GITHUB_WORKFLOW_REF"] == "#{REPOSITORY}/#{WORKFLOW}@refs/heads/#{branch}"
      raise Error, "The CI repository, branch or workflow does not match the release workflow."
    end
    raise Error, "CI reruns are not allowed to upload." unless env["GITHUB_RUN_ATTEMPT"] == "1"
    unless env["GITHUB_SHA"].to_s.match?(SHA_PATTERN) && env[VERIFIED_SHA] == env["GITHUB_SHA"] &&
           env[VERIFIED_PR].to_s.match?(/\A[1-9]\d{0,9}\z/)
      raise Error, "The merge verification result is missing or does not match the CI SHA."
    end
    branch
  end

  # Returns the verified SHA and the push's `before` (for the first-parent comparison).
  def context!(lane:, env:, event:)
    branch = environment!(lane: lane, env: env)
    sha = env["GITHUB_SHA"]
    unless event.is_a?(Hash) && event["ref"] == "refs/heads/#{branch}" &&
           event.dig("repository", "full_name") == REPOSITORY &&
           event["created"] == false && event["deleted"] == false && event["forced"] == false &&
           event["after"] == sha && event["before"].is_a?(String) &&
           event["before"].match?(SHA_PATTERN) && !event["before"].match?(/\A0+\z/)
      raise Error, "Only a push that is not a branch creation, deletion or force push may upload."
    end
    [sha, event["before"]]
  rescue TypeError, NoMethodError
    raise Error, "The CI push event is malformed."
  end

  def current!(sha:, head_sha:, branch_sha:, dirty_count:)
    unless head_sha == sha && branch_sha == sha
      raise Error, "The checkout must be the merge SHA and still the live tip of the target branch."
    end
    raise Error, "The checkout is dirty or its state cannot be read." unless dirty_count == 0
  end

  def validate!(lane:, env:, event:, head_sha:, branch_sha:, dirty_count:, first_parent:, changed_paths:)
    sha, before = context!(lane: lane, env: env, event: event)
    current!(sha: sha, head_sha: head_sha, branch_sha: branch_sha, dirty_count: dirty_count)
    raise Error, "The first parent is not the push's before (direct push?)." unless first_parent == before
    unless changed_paths.is_a?(Array) && changed_paths.all? { |path| path.is_a?(String) && !path.empty? } &&
           changed_paths.any? { |path| path != SHIPPED_RECORD }
      raise Error, "A record-only or empty change is not released."
    end
    sha
  end

  def git_output(repo_root, *arguments, source_token: nil)
    child_env = child_environment
    if source_token && !source_token.empty?
      child_env.merge!("GIT_CONFIG_COUNT" => "1", "GIT_CONFIG_KEY_0" => "http.https://github.com/.extraheader",
                       "GIT_CONFIG_VALUE_0" => "AUTHORIZATION: basic #{["x-access-token:#{source_token}"].pack("m0")}",
                       "GIT_TRACE" => nil, "GIT_TRACE_CURL" => nil, "GIT_CURL_VERBOSE" => nil)
    end
    output, status = Open3.capture2e(child_env, "git", "-C", repo_root, *arguments)
    raise Error, "Cannot read Git information for the release." unless status.success?

    output
  rescue SystemCallError
    raise Error, "Cannot read Git information for the release."
  end

  # A cached remote-tracking ref cannot reveal a merge that landed while waiting, so ask the remote.
  def branch_sha(repo_root, branch:, source_token: nil)
    raise Error, "The target branch is not allowed." unless BRANCHES.include?(branch)

    ref = "refs/heads/#{branch}"
    fields = git_output(repo_root, "ls-remote", "--exit-code", "origin", ref, source_token: source_token).strip.split(/\s+/)
    unless fields.size == 2 && fields[0].match?(SHA_PATTERN) && fields[1] == ref
      raise Error, "Cannot read the live tip of the target branch."
    end
    fields[0]
  end

  def read_event(env)
    JSON.parse(File.read(env.fetch("GITHUB_EVENT_PATH")))
  rescue JSON::ParserError, KeyError, SystemCallError, IOError
    raise Error, "Cannot read the CI push event."
  end

  def git_state(repo_root)
    [GitState.head_sha(repo_root, child_env: child_environment), GitState.dirty_count(repo_root, child_env: child_environment)]
  rescue GitState::Error => error
    raise Error, error.message
  end

  # Runs before any credential, keychain or build work. Local invocations stop here.
  def authorize!(lane:, repo_root:, env: ENV, source_token: env["RELEASE_SOURCE_READ_TOKEN"])
    branch = environment!(lane: lane, env: env)
    event = read_event(env)
    sha, = context!(lane: lane, env: env, event: event)
    parent = git_output(repo_root, "rev-parse", "--verify", "#{sha}^1^{commit}").strip
    paths = git_output(repo_root, "diff", "--name-only", "-z", "#{sha}^1", sha, "--").split("\0")
    head, dirty = git_state(repo_root)
    validate!(
      lane: lane, env: env, event: event,
      head_sha: head, branch_sha: branch_sha(repo_root, branch: branch, source_token: source_token),
      dirty_count: dirty, first_parent: parent, changed_paths: paths
    )
  end

  # Called immediately before upload: the authorized checkout must still be clean and still the live tip.
  def verify_current!(repo_root:, sha:, env: ENV, source_token: env["RELEASE_SOURCE_READ_TOKEN"])
    branch = environment!(lane: :beta, env: env)
    event = read_event(env)
    unless context!(lane: :beta, env: env, event: event).first == sha
      raise Error, "The CI merge SHA changed after the build started."
    end
    head, dirty = git_state(repo_root)
    current!(sha: sha, head_sha: head, branch_sha: branch_sha(repo_root, branch: branch, source_token: source_token), dirty_count: dirty)
  end
end

if __FILE__ == $PROGRAM_NAME
  begin
    root = File.expand_path("../..", __dir__)
    puts "CI deployment target: #{DeploymentPolicy.authorize!(lane: :beta, repo_root: root)}"
  rescue DeploymentPolicy::Error => error
    warn error.message
    exit 1
  end
end
