# End-to-end contract of one release with a fake Fastlane/Xcode/Apple adapter and a fake `security`:
# ordering, credential isolation, readonly match, keychain cleanup, numbering, copy and checkout cleanness.
require_relative "test_helper"
require "openssl"
require "open3"
require_relative "../lib/release_pipeline"

PREFIX_SHA = DeploymentPolicy::VERIFIED_SHA
PREFIX_PR = DeploymentPolicy::VERIFIED_PR
APP_ID = ReleaseConfig::APP_IDENTIFIER

def git!(dir, *args)
  out, status = Open3.capture2e("git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", *args)
  raise "git #{args.first} failed: #{out}" unless status.success?

  out
end

# A real repository whose HEAD is the "merge": a base commit, then a merge commit with two parents.
def build_seed_repo(dir)
  FileUtils.mkdir_p(dir)
  git!(dir, "init", "-q", "-b", "develop")
  FileUtils.mkdir_p(File.join(dir, ReleaseConfig::PROJECT))
  File.write(File.join(dir, ReleaseConfig::PROJECT, "project.pbxproj"), "CURRENT_PROJECT_VERSION = 5;\nCURRENT_PROJECT_VERSION = 5;\n")
  File.write(File.join(dir, ".gitignore"), "build/\n")
  git!(dir, "add", ".")
  git!(dir, "commit", "-q", "-m", "test(ci): add base fixture")
  before = git!(dir, "rev-parse", "HEAD").strip
  git!(dir, "checkout", "-q", "-b", "feature")
  File.write(File.join(dir, "feature.txt"), "x")
  git!(dir, "add", ".")
  git!(dir, "commit", "-q", "-m", "test(ci): add feature fixture")
  git!(dir, "checkout", "-q", "develop")
  git!(dir, "merge", "-q", "--no-ff", "-m", "test(ci): merge fixture", "feature")
  [git!(dir, "rev-parse", "HEAD").strip, before]
end


# Each case gets an isolated copy; building the same immutable history repeatedly wastes API checks.
def make_repo(dir)
  unless defined?($release_fixture_seed) && $release_fixture_seed
    seed = Dir.mktmpdir("release-fixture-seed-")
    sha, before = build_seed_repo(File.join(seed, "repo"))
    $release_fixture_seed = [seed, sha, before]
    at_exit { FileUtils.rm_rf(seed) }
  end
  seed, sha, before = $release_fixture_seed
  FileUtils.mkdir_p(File.dirname(dir))
  FileUtils.cp_r(File.join(seed, "repo"), dir)
  [sha, before]
end

# Sibling checkouts are pinned by revision; the test creates real ones and pins their actual SHA.
def build_seed_siblings(parent)
  pins = ReleaseConfig::SIBLINGS.keys.to_h do |name|
    path = File.join(parent, name)
    FileUtils.mkdir_p(path)
    git!(path, "init", "-q", "-b", "main")
    File.write(File.join(path, "Package.swift"), "// #{name}")
    git!(path, "add", ".")
    git!(path, "commit", "-q", "-m", "test(ci): pin sibling fixture")
    [name, git!(path, "rev-parse", "HEAD").strip]
  end
  ReleaseConfig.send(:remove_const, :SIBLINGS)
  ReleaseConfig.const_set(:SIBLINGS, pins.freeze)
end


def make_siblings(parent)
  return if ReleaseConfig::SIBLINGS.empty?
  unless defined?($release_sibling_seed) && $release_sibling_seed
    seed = Dir.mktmpdir("release-sibling-seed-")
    build_seed_siblings(seed)
    $release_sibling_seed = [seed, ReleaseConfig::SIBLINGS.dup]
    at_exit { FileUtils.rm_rf(seed) }
  end
  seed, pins = $release_sibling_seed
  pins.each_key { |name| FileUtils.cp_r(File.join(seed, name), File.join(parent, name)) }
end

def ec_key_pem = OpenSSL::PKey::EC.generate("prime256v1").to_pem

class FakeSecurity
  attr_reader :calls
  attr_accessor :fail_on

  def initialize
    @calls = []
    @fail_on = nil
  end

  def call(*args)
    @calls << args
    return ["", false] if @fail_on && args.first == @fail_on
    return ["    \"/fixture/login.keychain-db\"\n    \"/fixture/second.keychain-db\"\n", true] if args == ["list-keychains", "-d", "user"]

    ["", true]
  end
end

class FakeAdapter
  attr_reader :events, :seen, :match_args, :archive_args, :upload_args, :set_signing_calls
  attr_accessor :remote, :ipa_info, :fail_at, :on_upload

  def initialize(repo_root, sha, env, home)
    @repo_root = repo_root
    @sha = sha
    @env = env
    @home = home
    @events = []
    @seen = {}
    @remote = 9
    @set_signing_calls = []
    @fail_at = nil
    @ipa_info = nil
  end

  def credential_env = @env.keys.select { |name| DeploymentPolicy.credential_name?(name) }
  def step(name)
    @events << name
    raise "#{name} failed" if @fail_at == name
  end

  def asc_api_key(key_id:, issuer_id:, pem:)
    step(:asc)
    @asc = { key_id: key_id, issuer_id: issuer_id, pem: pem }
    :api_key
  end

  def match_signing(**args)
    step(:match)
    @match_args = args
    @seen[:match_env] = @env.to_h.slice("MATCH_PASSWORD", "MATCH_GIT_BASIC_AUTHORIZATION").keys.sort
    ReleaseConfig::TARGETS.values.to_h { |id| [id, "profile #{id}"] }
  end

  def marketing_version(project:, target:)
    step(:version)
    "1.2.3"
  end

  def remote_build_number(**)
    step(:remote)
    @remote
  end

  def set_signing(project:, target:, profile:, team:)
    step(:signing)
    @set_signing_calls << [project, target, profile, team]
  end

  def resolve_packages(project:, scheme:, packages:)
    step(:resolve)
    @seen[:resolve_env] = credential_env
    @seen[:netrc_during_resolve] = File.file?(File.join(@home, ".netrc")) && File.stat(File.join(@home, ".netrc")).mode & 0o777
  end

  def archive(project:, scheme:, profiles:, packages:, derived_data:, output:, team:)
    step(:archive)
    @archive_args = { project: project, output: output, derived_data: derived_data, profiles: profiles }
    @seen[:archive_env] = credential_env
    @seen[:netrc_during_archive] = File.exist?(File.join(@home, ".netrc")) ? File.read(File.join(@home, ".netrc")) : ""
    @seen[:plist] = ReleaseConfig::SECRET_FILES.to_h { |_, spec| [spec[:path], File.exist?(File.join(File.dirname(project), spec[:path]))] }
    FileUtils.mkdir_p(output)
    ipa = File.join(output, "#{scheme}.ipa")
    File.write(ipa, "ipa")
    ipa
  end

  def inspect_ipa(_ipa)
    step(:inspect)
    @ipa_info || {
      app: { id: APP_ID, version: "1.2.3", build: @built.to_s, team: ReleaseConfig::TEAM_ID },
      extensions: ReleaseConfig::EXTENSION_IDENTIFIERS.map { |id| { id: id, version: "1.2.3", build: @built.to_s, team: ReleaseConfig::TEAM_ID } }
    }
  end

  def built!(number) = @built = number

  def upload(api_key:, ipa:, app_identifier:, options:)
    step(:upload)
    @on_upload&.call
    @upload_args = { ipa: ipa, home: @env["HOME"], tmp: @env["TMPDIR"], options: options }
  end
end

# Subclass so the expected build number can be read from the copied project at archive time.
class NumberingAdapter < FakeAdapter
  def archive(project:, **rest)
    built!(File.read(File.join(project, "project.pbxproj"))[/CURRENT_PROJECT_VERSION = (\d+);/, 1].to_i)
    super(project: project, **rest)
  end
end

class Harness
  attr_reader :root, :repo, :temp, :home, :sha, :before, :env, :security, :adapter, :out

  def initialize(dir, branch: "develop", run_number: "100", overrides: {})
    @root = dir
    @repo = File.join(dir, "checkout", ReleaseConfig::APP_NAME)
    @sha, @before = make_repo(@repo)
    make_siblings(File.join(dir, "checkout"))
    @temp = File.join(dir, "runner_temp")
    @home = File.join(dir, "home")
    FileUtils.mkdir_p([@temp, @home])
    event_path = File.join(dir, "event.json")
    File.write(event_path, JSON.generate(
      "ref" => "refs/heads/develop", "before" => @before, "after" => @sha, "created" => false,
      "deleted" => false, "forced" => false, "repository" => { "full_name" => ReleaseConfig::REPOSITORY }
    ))
    fake_git = File.join(dir, "bin")
    FileUtils.mkdir_p(fake_git)
    real = ENV["PATH"].split(":").map { |d| File.join(d, "git") }.find { |f| File.executable?(f) }
    # ls-remote is answered locally; every other git command is the real one.
    File.write(File.join(fake_git, "git"), <<~SH)
      #!/bin/sh
      for a in "$@"; do if [ "$a" = "ls-remote" ]; then printf '%s\\trefs/heads/develop\\n' "$(cat #{dir}/live_tip)"; exit 0; fi; done
      exec #{real} "$@"
    SH
    File.chmod(0o755, File.join(fake_git, "git"))
    File.write(File.join(dir, "live_tip"), @sha)
    @env = {
      "GITHUB_ACTIONS" => "true", "RUNNER_ENVIRONMENT" => "self-hosted", "GITHUB_EVENT_NAME" => "push",
      "GITHUB_REPOSITORY" => ReleaseConfig::REPOSITORY, "GITHUB_REF" => "refs/heads/develop",
      "GITHUB_WORKFLOW_REF" => "#{ReleaseConfig::REPOSITORY}/#{ReleaseConfig::WORKFLOW}@refs/heads/develop",
      "GITHUB_RUN_ATTEMPT" => "1", "GITHUB_RUN_NUMBER" => run_number, "GITHUB_SHA" => @sha,
      PREFIX_SHA => @sha, PREFIX_PR => "7", "GITHUB_EVENT_PATH" => event_path,
      "RUNNER_TEMP" => @temp, "RELEASE_WORK" => File.join(@temp, "release-work"),
      "PATH" => "#{fake_git}:#{ENV['PATH']}",
      "TESTFLIGHT_ASC_KEY_ID" => "ABCDE12345", "TESTFLIGHT_ASC_ISSUER_ID" => "69a6de70-03db-47e3-e053-5b8c7c11a4d1",
      "TESTFLIGHT_ASC_KEY_CONTENT" => [ec_key_pem].pack("m0"),
      "TESTFLIGHT_MATCH_PASSWORD" => "match-pw", "TESTFLIGHT_MATCH_GIT_TOKEN" => "ghs_signing",
      "TESTFLIGHT_QUANTUMLEAP_READ_TOKEN" => "ghs_dependency",
      "GITHUB_TOKEN" => "ghs_job"
    }
    ReleaseConfig::SECRET_FILES.each do |name, spec|
      @env[name] = "<?xml version=\"1.0\"?><plist><dict><key>GOOGLE_APP_ID</key><string>1:2:ios:3</string><key>BUNDLE_ID</key><string>#{spec[:bundle_id]}</string></dict></plist>"
    end
    tip = overrides.delete("LIVE_TIP")
    File.write(File.join(dir, "live_tip"), tip) if tip
    @env.merge!(overrides)
    @env.delete_if { |_, value| value.nil? }
    @security = FakeSecurity.new
    @adapter = NumberingAdapter.new(@repo, @sha, @env, @home)
    @out = StringIO.new
  end

  def tip=(value)
    File.write(File.join(@root, "live_tip"), value)
  end

  # The policy shells out to git through the process PATH, so the fake git is installed there.
  def run
    with_environment("PATH" => @env["PATH"]) do
      ReleasePipeline.run(adapter: @adapter, repo_root: @repo, env: @env, runner: @security, home: @home, out: @out)
    end
  end

  def tree_state = [git!(@repo, "rev-parse", "HEAD"), git!(@repo, "status", "--porcelain", "--untracked-files=all", "--ignored")]
end

require "stringio"

def harness(**options)
  Dir.mktmpdir("pipeline") do |dir|
    yield Harness.new(dir, **options)
  end
end

check "a verified merge builds from a copy, uploads, records outside the source, and leaves the checkout untouched" do
  harness do |h|
    before = h.tree_state
    h.run
    assert h.tree_state == before, "the authorized checkout changed: #{h.tree_state.inspect}"
    expected = %i[asc match version remote] + [:signing] * ReleaseConfig::TARGETS.length + %i[resolve archive inspect upload]
    assert h.adapter.events == expected, h.adapter.events.inspect
    assert h.adapter.archive_args[:project].start_with?(h.temp), "built inside the source checkout"
    assert !h.adapter.archive_args[:project].start_with?(h.repo)
    assert h.adapter.archive_args[:output].start_with?(h.temp) && h.adapter.archive_args[:derived_data].start_with?(h.temp)
    record = JSON.parse(File.read(File.join(h.temp, "release-record", "last_shipped.json")))
    assert record["sha"] == h.sha && record["pr"] == 7 && record["build"] == 100, record.inspect
    assert !File.exist?(File.join(h.repo, "fastlane/testflight/last_shipped.json")), "record written into the source"
    assert !File.exist?(File.join(h.temp, "release-work")), "work directory was not removed"
  end
end

check "the build number is max(remote+1, CI run number, project+1, minimum+1)" do
  floor = ReleaseConfig::MINIMUM_BUILD + 1
  { [9, "100"] => 100, [150, "100"] => 151, [3, "2"] => [6, floor].max }.each do |(remote, run), expected|
    harness(run_number: run) do |h|
      h.adapter.remote = remote
      h.run
      assert h.adapter.upload_args && File.exist?(File.join(h.temp, "release-record", "last_shipped.json"))
      assert JSON.parse(File.read(File.join(h.temp, "release-record", "last_shipped.json")))["build"] == expected, "remote=#{remote} run=#{run}"
    end
  end
end

check "the number is assigned in the copy before the archive and not in the original project" do
  harness do |h|
    original = File.read(File.join(h.repo, ReleaseConfig::PROJECT, "project.pbxproj"))
    h.run
    assert File.read(File.join(h.repo, ReleaseConfig::PROJECT, "project.pbxproj")) == original
    assert h.adapter.set_signing_calls.length == ReleaseConfig::TARGETS.length, "signing must be target-specific per target"
    assert h.adapter.set_signing_calls.map { |c| c[1] } == ReleaseConfig::TARGETS.keys
  end
end

check "match runs read-only inputs only: bundle ids, no force flags, MATCH secrets only during match" do
  harness do |h|
    h.run
    assert h.adapter.match_args[:app_identifiers] == ReleaseConfig::TARGETS.values, "both bundle identifiers must be matched"
    assert h.adapter.seen[:match_env] == %w[MATCH_GIT_BASIC_AUTHORIZATION MATCH_PASSWORD], h.adapter.seen[:match_env].inspect
    assert h.adapter.seen[:resolve_env].empty? && h.adapter.seen[:archive_env].empty?, "credentials reached an Xcode child"
    assert (h.env.keys & %w[MATCH_PASSWORD MATCH_GIT_BASIC_AUTHORIZATION]).empty?, "MATCH variables remained after match"
  end
end

check "a credential that reappears during signing is still stripped from resolution and archive children" do
  harness do |h|
    leaking = h.env
    h.adapter.define_singleton_method(:set_signing) do |**args|
      leaking["MATCH_KEYCHAIN_PASSWORD"] = "late-secret"
      leaking["GITHUB_TOKEN"] = "late-token"
      super(**args)
    end
    h.run
    assert h.adapter.seen[:resolve_env].empty? && h.adapter.seen[:archive_env].empty?,
           "children saw #{(h.adapter.seen[:resolve_env] + h.adapter.seen[:archive_env]).inspect}"
    assert h.env["MATCH_KEYCHAIN_PASSWORD"] == "late-secret", "scrub must restore values afterwards"
  end
end

check "the real adapter requests readonly match unconditionally and ignores environment switches" do
  source = File.read(File.expand_path("../lib/fastlane_adapter.rb", __dir__))
  assert source.include?("readonly: true") && source.include?("force: false")
  assert !source.match?(/MATCH_FETCH_READ_ONLY_MODE|readonly: ENV|ENV\[.MATCH_READONLY/)
  assert !source.match?(/readonly: false/)
end

check "the dependency token exists only as a private ~/.netrc during resolution and is removed afterwards" do
  harness do |h|
    File.write(File.join(h.home, ".netrc"), "original credentials\n")
    h.run
    assert h.adapter.seen[:netrc_during_resolve] == 0o600, "netrc mode: #{h.adapter.seen[:netrc_during_resolve].inspect}"
    assert !h.adapter.seen[:netrc_during_archive].include?("ghs_dependency"), "dependency credentials were present during the archive"
    assert File.read(File.join(h.home, ".netrc")) == "original credentials\n", "original netrc not restored"
  end
end

check "no credential is passed on stdout; masks are registered for the derived values" do
  harness do |h|
    h.run
    text = h.out.string
    assert text.include?("::add-mask::#{['x-access-token:ghs_signing'].pack("m0")}") && text.include?("::add-mask::ghs_dependency")
    assert !text.include?("match-pw")
  end
end

check "the upload runs with a private HOME/TMPDIR under the work directory and restores them" do
  harness do |h|
    h.env["HOME"] = "/original/home"
    h.env["TMPDIR"] = "/original/tmp"
    h.run
    assert h.adapter.upload_args[:home].start_with?(h.temp) && h.adapter.upload_args[:tmp].start_with?(h.temp), h.adapter.upload_args.inspect
    assert h.env["HOME"] == "/original/home" && h.env["TMPDIR"] == "/original/tmp"
  end
end

# Everything below must stop BEFORE credentials, keychain or build work.
{
  "local execution" => { "GITHUB_ACTIONS" => nil },
  "manual dispatch" => { "GITHUB_EVENT_NAME" => "workflow_dispatch" },
  "a rerun" => { "GITHUB_RUN_ATTEMPT" => "2" },
  "a missing verifier result" => { PREFIX_SHA => nil },
  "a hosted runner" => { "RUNNER_ENVIRONMENT" => "github-hosted" },
  "a stale branch tip" => { "LIVE_TIP" => OTHER }
}.each do |name, overrides|
  check "#{name} is rejected before credentials, keychain or build" do
    harness(overrides: overrides) do |h|
      error = error_of(DeploymentPolicy::Error) { h.run }
      assert error, "release was authorized"
      assert h.adapter.events.empty? && h.security.calls.empty?, "work started: #{h.adapter.events.inspect} #{h.security.calls.inspect}"
    end
  end
end

check "a dirty authorized checkout is rejected before any work" do
  harness do |h|
    File.write(File.join(h.repo, "stray.txt"), "x")
    assert error_of(DeploymentPolicy::Error) { h.run }
    assert h.adapter.events.empty? && h.security.calls.empty?
  end
end

# Missing context and secrets: no fallback to old names.
Credentials.required.each do |name|
  check "missing #{name} stops before the keychain and builds nothing" do
    harness(overrides: { name => nil }) do |h|
      error = error_of(Credentials::Error) { h.run }
      assert error && error.message.include?(name), error.inspect
      assert h.adapter.events.empty? && h.security.calls.empty?, "work started"
      assert !error.message.match?(/match-pw|ghs_/), "a value leaked into the message"
    end
  end
end

check "legacy secret names are never used as a fallback" do
  legacy = { "ASC_KEY_ID" => "ABCDE12345", "APP_STORE_CONNECT_API_KEY_KEY_ID" => "ABCDE12345", "MATCH_PASSWORD" => "pw",
             "MATCH_GIT_TOKEN" => "tok", "MATCH_GIT_BASIC_AUTHORIZATION" => "x", "QUANTUMLEAP_READ_TOKEN" => "t" }
  harness(overrides: legacy.merge("TESTFLIGHT_MATCH_PASSWORD" => nil, "TESTFLIGHT_QUANTUMLEAP_READ_TOKEN" => nil)) do |h|
    error = error_of(Credentials::Error) { h.run }
    assert error && error.message.include?("TESTFLIGHT_MATCH_PASSWORD") && h.adapter.events.empty?
  end
end

check "an incoherent ASC triple is rejected before any work" do
  [
    { "TESTFLIGHT_ASC_KEY_ID" => "short" },
    { "TESTFLIGHT_ASC_ISSUER_ID" => "not-a-uuid" },
    { "TESTFLIGHT_ASC_KEY_CONTENT" => "bm90IGEga2V5" },
    { "TESTFLIGHT_ASC_KEY_CONTENT" => [OpenSSL::PKey::RSA.new(2048).to_pem].pack("m0") },
    { "TESTFLIGHT_ASC_KEY_CONTENT" => "%%%" }
  ].each do |overrides|
    harness(overrides: overrides) do |h|
      error = error_of(Credentials::Error) { h.run }
      assert error, "accepted #{overrides.keys.first}"
      assert h.adapter.events.empty? && h.security.calls.empty?
    end
  end
end

check "the ASC key reaches the adapter only as in-memory PEM and is never written to disk" do
  harness do |h|
    h.run
    assert h.adapter.instance_variable_get(:@asc)[:pem].start_with?("-----BEGIN EC PRIVATE KEY-----")
    leaked = Dir.glob(File.join(h.root, "**", "*"), File::FNM_DOTMATCH).select { |p| File.file?(p) && File.read(p).include?("PRIVATE KEY") }
    assert leaked.empty?, "key material found on disk: #{leaked.inspect}"
  end
end

# Keychain handling.
check "the keychain search list is restored and the temporary keychain deleted after success" do
  harness do |h|
    h.run
    calls = h.security.calls
    assert calls.index { |c| c.first == "create-keychain" } < calls.index { |c| c.first == "delete-keychain" }
    restore = ["list-keychains", "-d", "user", "-s", "/fixture/login.keychain-db", "/fixture/second.keychain-db"]
    assert calls.include?(restore), "search list not restored"
    assert calls.last.first == "delete-keychain"
  end
end

check "the keychain is cleaned up when the archive fails, and the build failure is preserved" do
  harness do |h|
    h.adapter.fail_at = :archive
    error = error_of(RuntimeError) { h.run }
    assert error && error.message == "archive failed", error.inspect
    assert h.security.calls.any? { |c| c.first == "delete-keychain" }, "keychain not deleted"
    assert !File.exist?(File.join(h.temp, "release-work")) && !File.exist?(File.join(h.temp, "release-record", "last_shipped.json"))
    assert (h.env.keys & Credentials.required).empty?, "credentials remained in the environment after failure"
  end
end

check "keychain cleanup failure is surfaced as an error after a successful upload" do
  harness do |h|
    h.security.fail_on = "delete-keychain"
    error = error_of(Keychain::Error) { h.run }
    assert error && error.message.include?("delete keychain"), error.inspect
  end
end

check "keychain setup failure aborts before match, signing or build" do
  %w[create-keychain unlock-keychain].each do |step|
    harness do |h|
      h.security.fail_on = step
      assert error_of(Keychain::Error) { h.run }
      assert !h.adapter.events.include?(:match) && !h.adapter.events.include?(:archive)
      assert h.security.calls.any? { |c| c.first == "delete-keychain" }
    end
  end
end

check "an unreadable keychain search list fails closed" do
  harness do |h|
    h.security.fail_on = "list-keychains"
    assert error_of(Keychain::Error) { h.run }
    assert !h.adapter.events.include?(:match)
  end
end

# Clean-original and live-tip rechecks at upload.
check "a dirtied original checkout stops the upload and records nothing" do
  harness do |h|
    h.adapter.define_singleton_method(:inspect_ipa) { |_| File.write(File.join(@repo_root, "late.txt"), "x"); super(_) }
    assert error_of(DeploymentPolicy::Error) { h.run }
    assert !h.adapter.events.include?(:upload) && !File.exist?(File.join(h.temp, "release-record", "last_shipped.json"))
  end
end

check "the target branch advancing during the build stops the upload" do
  harness do |h|
    harness_ref = h
    h.adapter.define_singleton_method(:inspect_ipa) { |ipa| harness_ref.tip = OTHER; super(ipa) }
    assert error_of(DeploymentPolicy::Error) { h.run }
    assert !h.adapter.events.include?(:upload)
  end
end

check "an IPA with the wrong identity, version, build, team or extensions is not uploaded" do
  good = lambda do |build|
    {
      app: { id: APP_ID, version: "1.2.3", build: build.to_s, team: ReleaseConfig::TEAM_ID },
      extensions: ReleaseConfig::EXTENSION_IDENTIFIERS.map { |id| { id: id, version: "1.2.3", build: build.to_s, team: ReleaseConfig::TEAM_ID } }
    }
  end
  mutations = {
    "bundle id" => ->(i) { i[:app][:id] = "x.y" },
    "version" => ->(i) { i[:app][:version] = "9.9" },
    "build" => ->(i) { i[:app][:build] = "1" },
    "team" => ->(i) { i[:app][:team] = "OTHERTEAM1" },
    "extra extension" => ->(i) { i[:extensions] << { id: "jp.x.ext", version: "1.2.3", build: "100", team: ReleaseConfig::TEAM_ID } },
    "no app" => ->(i) { i.delete(:app) }
  }
  unless ReleaseConfig::EXTENSION_IDENTIFIERS.empty?
    mutations["missing extension"] = ->(i) { i[:extensions].clear }
    mutations["extension build"] = ->(i) { i[:extensions][0][:build] = "1" }
    mutations["extension team"] = ->(i) { i[:extensions][0][:team] = "OTHERTEAM1" }
  end
  mutations.each do |name, mutate|
    harness do |h|
      info = good.call(100)
      mutate.call(info)
      h.adapter.ipa_info = info
      assert error_of(IpaVerifier::Error) { h.run }, "#{name} was accepted"
      assert !h.adapter.events.include?(:upload)
    end
  end
end

check "an IPA written outside the output directory is rejected" do
  harness do |h|
    outside = File.join(h.root, "elsewhere.ipa")
    File.write(outside, "x")
    h.adapter.define_singleton_method(:archive) { |**| outside }
    assert error_of(ReleasePipeline::Error) { h.run }
    assert !h.adapter.events.include?(:upload)
  end
end

check "the build copy contains the merged tree only; ignored and untracked files stay behind" do
  harness do |h|
    FileUtils.mkdir_p(File.join(h.repo, "build"))
    File.write(File.join(h.repo, "build", "cache.bin"), "x")
    copied = nil
    h.adapter.define_singleton_method(:resolve_packages) do |project:, **|
      copied = Dir.glob(File.join(File.dirname(project), "**", "*"), File::FNM_DOTMATCH).map { |p| p.sub(File.dirname(project) + "/", "") }
      super(project: project, scheme: nil, packages: nil)
    end
    h.run
    assert copied.include?("feature.txt") && !copied.any? { |p| p.start_with?("build") || p.start_with?(".git/") }, copied.inspect
  end
end

check "a work or runner directory inside the authorized checkout is refused" do
  harness do |h|
    h.env["RUNNER_TEMP"] = File.join(h.repo, "tmp")
    h.env["RELEASE_WORK"] = File.join(h.repo, "tmp", "work")
    FileUtils.mkdir_p(h.env["RUNNER_TEMP"])
    assert error_of(ReleasePipeline::Error, DeploymentPolicy::Error) { h.run }
    assert h.adapter.events.empty?
  end
end

check "a RELEASE_WORK outside RUNNER_TEMP is refused" do
  harness do |h|
    h.env["RELEASE_WORK"] = File.join(h.root, "elsewhere")
    assert error_of(ReleasePipeline::Error) { h.run }
    assert h.adapter.events.empty?
  end
end

check "a retained recovery backup survives a new release invocation" do
  harness do |h|
    state = File.join(h.temp, "release-state")
    FileUtils.mkdir_p(state)
    backup = File.join(state, "original.netrc")
    File.write(backup, "original-user-credentials")
    error = error_of(ReleasePipeline::Error) { h.run }
    assert error && error.message.include?("Pending cleanup")
    assert File.read(backup) == "original-user-credentials"
    assert h.adapter.events.empty? && h.security.calls.empty?
  end
end

unless ReleaseConfig::SECRET_FILES.empty?
  check "the app-specific secret file exists only in the build copy and is never printed" do
    harness do |h|
      h.run
      assert h.adapter.seen[:plist].values.all?, "secret file missing from the build copy"
      spec = ReleaseConfig::SECRET_FILES.values.first
      assert !File.exist?(File.join(h.repo, spec[:path])), "secret file written into the authorized checkout"
      assert !h.out.string.include?("GOOGLE_APP_ID"), "secret content logged"
      assert File.read(File.join(h.repo, ".gitignore")).include?("build/")
    end
  end

  check "a secret file for the wrong bundle, malformed content or base64 junk is rejected before the keychain" do
    name = ReleaseConfig::SECRET_FILES.keys.first
    ["<plist><dict><key>GOOGLE_APP_ID</key><string>1</string><key>BUNDLE_ID</key><string>wrong.bundle</string></dict></plist>", "not a plist", "%%%"].each do |content|
      harness(overrides: { name => content }) do |h|
        error = error_of(Credentials::Error) { h.run }
        assert error && !error.message.include?(content[0, 12]) || content == "%%%", error.inspect
        assert !h.adapter.events.include?(:archive)
      end
    end
  end
end

finish
