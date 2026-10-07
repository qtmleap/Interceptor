# Orchestrates one guarded TestFlight release. fastlane, Xcode and Apple are behind `adapter`,
# so the ordering and safety properties are tested with fakes (see test/release_pipeline_test.rb).
require "fileutils"
require "json"
require "time"
require_relative "release_config"
require_relative "deployment_policy"
require_relative "credentials"
require_relative "keychain"
require_relative "build_number"
require_relative "build_copy"
require_relative "package_auth"
require_relative "ipa_verifier"

module ReleasePipeline
  class Error < StandardError; end

  RECORD_NAME = "last_shipped.json"

  module_function

  def inside?(path, root)
    BuildCopy.inside?(path, root)
  end

  # Work, state and record directories are private run directories outside the authorized checkout.
  def directories!(env, repo_root)
    temp = env["RUNNER_TEMP"].to_s
    work = env["RELEASE_WORK"].to_s
    raise Error, "RUNNER_TEMP is not set." if temp.empty? || !File.absolute_path?(temp)
    unless !work.empty? && File.absolute_path?(work) && inside?(work, temp) && work != File.expand_path(temp)
      raise Error, "RELEASE_WORK must be a directory inside RUNNER_TEMP."
    end
    raise Error, "RUNNER_TEMP must be outside the authorized checkout." if inside?(temp, repo_root)

    temp = File.expand_path(temp)
    [File.expand_path(work), File.join(temp, "release-state"), File.join(temp, "release-record")]
  end

  def with_env(env, values)
    saved = values.keys.to_h { |name| [name, env[name]] }
    values.each { |name, value| env[name] = value }
    yield
  ensure
    saved.each { |name, value| value.nil? ? env.delete(name) : env[name] = value }
  end

  def signing_targets(profiles)
    ReleaseConfig::TARGETS.each_with_object({}) do |(target, identifier), result|
      profile = profiles.respond_to?(:[]) ? profiles[identifier] : nil
      raise Error, "Missing App Store profile for #{identifier}." if profile.to_s.strip.empty?

      result[target] = profile
    end
  end

  def install_secret_files!(copy, credentials)
    ReleaseConfig::SECRET_FILES.each do |name, spec|
      destination = File.expand_path(spec.fetch(:path), copy)
      raise Error, "#{name} would be written outside the build copy." unless inside?(destination, copy)

      content = Credentials::PlistSecret.normalize!(credentials.extras.fetch(name), bundle_id: spec.fetch(:bundle_id), name: name)
      FileUtils.mkdir_p(File.dirname(destination))
      File.open(destination, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(content) }
    end
  end

  def prepare_copy!(repo_root, sha, work)
    root = File.join(work, "src")
    copy = File.join(root, ReleaseConfig::APP_NAME)
    BuildCopy.extract!(repo_root: repo_root, sha: sha, dest: copy)
    ReleaseConfig::SIBLINGS.each do |name, rev|
      BuildCopy.extract_sibling!(source: File.expand_path("../#{name}", repo_root), rev: rev, dest: File.join(root, name))
    end
    pbxproj = File.join(copy, ReleaseConfig::PROJECT, "project.pbxproj")
    raise Error, "#{ReleaseConfig::PROJECT} is missing from the merged commit." unless File.file?(pbxproj)

    [copy, File.join(copy, ReleaseConfig::PROJECT), pbxproj]
  end

  def private_upload_environment(env, work)
    home = File.join(work, "upload-home")
    tmp = File.join(work, "upload-tmp")
    FileUtils.mkdir_p([home, tmp], mode: 0o700)
    with_env(env, "HOME" => home, "TMPDIR" => tmp) { yield }
  end

  def write_record(dir, sha:, pr:, build:, version:)
    FileUtils.mkdir_p(dir, mode: 0o700)
    record = { sha: sha, pr: pr, build: build, version: version, uploaded_at: Time.now.utc.iso8601 }
    File.write(File.join(dir, RECORD_NAME), JSON.pretty_generate(record) + "\n")
    record
  end

  def run(adapter:, repo_root:, env: ENV, runner: Keychain::SecurityRunner.new, home: Dir.home, out: $stdout)
    repo_root = File.expand_path(repo_root)
    # 1. Eligibility comes first: a local, manual, rerun or unverified invocation stops here,
    #    before credentials, keychains or any build work.
    source_token = env["RELEASE_SOURCE_READ_TOKEN"]
    sha = DeploymentPolicy.without_credentials(env) do
      DeploymentPolicy.authorize!(lane: :beta, repo_root: repo_root, env: env, source_token: source_token)
    end
    work, state, record_dir = directories!(env, repo_root)
    raise Error, "Pending cleanup must finish before another release." if File.exist?(state)
    # 2. Credentials are validated in memory and then removed from the process environment, so no
    #    child process inherits them. They are re-exposed only to the single step that needs them.
    credentials = Credentials.load!(env)
    env.keys.select { |name| DeploymentPolicy.credential_name?(name) }.each { |name| env.delete(name) }
    authorization = ["x-access-token:#{credentials.match_git_token}"].pack("m0")
    DeploymentPolicy.mask_lines(authorization, credentials.match_git_token, credentials.quantumleap_token).each { |line| out.puts(line) }

    FileUtils.rm_rf(record_dir)
    FileUtils.mkdir_p(work, mode: 0o700)
    begin
      build_and_upload(adapter, repo_root, env, sha, work, state, record_dir, credentials, authorization, runner, home, source_token)
    ensure
      FileUtils.rm_rf(work)
    end
  end

  def build_and_upload(adapter, repo_root, env, sha, work, state, record_dir, credentials, authorization, runner, home, source_token)
    config = ReleaseConfig
    copy, project, pbxproj = prepare_copy!(repo_root, sha, work)
    install_secret_files!(copy, credentials)
    api_key = adapter.asc_api_key(key_id: credentials.asc_key_id, issuer_id: credentials.asc_issuer_id, pem: credentials.asc_pem)

    Keychain.with_temporary(dir: File.join(work, "keychain"), state_dir: state, runner: runner) do |keychain, keychain_password|
      # Match is read-only and unconditional; the only place MATCH_ secrets exist in the environment.
      profiles = with_env(env, "MATCH_PASSWORD" => credentials.match_password, "MATCH_GIT_BASIC_AUTHORIZATION" => authorization) do
        adapter.match_signing(
          api_key: api_key, app_identifiers: config::TARGETS.values, git_url: config::MATCH_GIT_URL,
          keychain: keychain, keychain_password: keychain_password
        )
      end
      signing = signing_targets(profiles)
      version = adapter.marketing_version(project: project, target: config::APP_TARGET).to_s
      raise Error, "The marketing version is unreadable." unless version.match?(/\A\d+(\.\d+){0,2}\z/)

      remote = adapter.remote_build_number(api_key: api_key, app_identifier: config::APP_IDENTIFIER, version: version)
      number = BuildNumber.next(
        remote: remote, local: BuildNumber.project_floor(File.read(pbxproj)),
        minimum: config::MINIMUM_BUILD, ci_floor: env["GITHUB_RUN_NUMBER"]
      )
      # The number and the target-specific manual signing go into the temporary copy only.
      updated, = BuildNumber.apply(File.read(pbxproj), number)
      File.write(pbxproj, updated)
      signing.each { |target, profile| adapter.set_signing(project: project, target: target, profile: profile, team: config::TEAM_ID) }

      packages = File.join(work, "SourcePackages")
      # The dependency token exists only as a temporary ~/.netrc while packages are resolved.
      PackageAuth.with_netrc(home: home, token: credentials.quantumleap_token, state_dir: state) do
        DeploymentPolicy.without_credentials(env) { adapter.resolve_packages(project: project, scheme: config::SCHEME, packages: packages) }
      end
      output = File.join(work, "output")
      ipa = DeploymentPolicy.without_credentials(env) do
        adapter.archive(
          project: project, scheme: config::SCHEME, profiles: profiles_for_export(profiles), packages: packages,
          derived_data: File.join(work, "DerivedData"), output: output, team: config::TEAM_ID
        )
      end
      raise Error, "The archive produced no IPA." unless ipa.is_a?(String) && File.file?(ipa) && inside?(ipa, output)

      IpaVerifier.verify!(
        adapter.inspect_ipa(ipa), app_id: config::APP_IDENTIFIER, extension_ids: config::EXTENSION_IDENTIFIERS,
        team: config::TEAM_ID, version: version, build: number
      )
      # The original checkout must still be the clean, exact live tip immediately before upload.
      DeploymentPolicy.verify_current!(repo_root: repo_root, sha: sha, env: env, source_token: source_token)
      private_upload_environment(env, work) do
        adapter.upload(api_key: api_key, ipa: ipa, app_identifier: config::APP_IDENTIFIER, options: config::UPLOAD)
      end
      pr = env[DeploymentPolicy::VERIFIED_PR].to_i
      write_record(record_dir, sha: sha, pr: pr, build: number, version: version)
    end
  end

  def profiles_for_export(profiles)
    ReleaseConfig::TARGETS.values.to_h { |identifier| [identifier, profiles[identifier]] }
  end
end
