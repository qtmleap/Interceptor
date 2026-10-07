# Pure helpers: build numbers, project rewriting, credentials, keychain primitives, IPA checks.
require_relative "test_helper"
require_relative "../lib/build_number"
require_relative "../lib/credentials"
require_relative "../lib/keychain"
require_relative "../lib/ipa_verifier"
require_relative "../lib/package_auth"
require_relative "../lib/release_pipeline"

check "next build number takes the maximum of remote+1, project+1, minimum+1 and the CI run number" do
  assert BuildNumber.next(remote: 47, local: 30, minimum: 0, ci_floor: 5) == 48
  assert BuildNumber.next(remote: 0, local: 50, minimum: 0, ci_floor: 5) == 51
  assert BuildNumber.next(remote: 0, local: 0, minimum: 31, ci_floor: 5) == 32
  assert BuildNumber.next(remote: 3, local: 0, minimum: 0, ci_floor: 900) == 900
end

check "build number inputs are validated strictly" do
  [nil, "", "-1", "1.5", "abc", "1234567890", " 5"].each do |bad|
    assert error_of(BuildNumber::Error) { BuildNumber.next(remote: bad, local: 0, minimum: 0, ci_floor: 1) }, "accepted #{bad.inspect}"
  end
  assert error_of(BuildNumber::Error) { BuildNumber.next(remote: 0, local: 0, minimum: 0, ci_floor: 0) }
  assert error_of(BuildNumber::Error) { BuildNumber.next(remote: 999_999_999, local: 0, minimum: 0, ci_floor: 1) }
end

check "build number is rewritten in every configuration of a project text and unreadable text is refused" do
  text = "CURRENT_PROJECT_VERSION = 2;\nX = 1;\nCURRENT_PROJECT_VERSION = \"7\";\n"
  updated, count = BuildNumber.apply(text, 42)
  assert count == 2 && updated.scan("CURRENT_PROJECT_VERSION = 42;").length == 2
  assert BuildNumber.project_floor(text) == 7
  assert error_of(BuildNumber::Error) { BuildNumber.apply("nothing", 1) }
end

def pem = OpenSSL::PKey::EC.generate("prime256v1").to_pem

def good_env
  {
    "TESTFLIGHT_ASC_KEY_ID" => "ABCDE12345", "TESTFLIGHT_ASC_ISSUER_ID" => "69a6de70-03db-47e3-e053-5b8c7c11a4d1",
    "TESTFLIGHT_ASC_KEY_CONTENT" => pem, "TESTFLIGHT_MATCH_PASSWORD" => "pw", "TESTFLIGHT_MATCH_GIT_TOKEN" => "tok",
    "TESTFLIGHT_QUANTUMLEAP_READ_TOKEN" => "dep"
  }.tap do |env|
    ReleaseConfig::SECRET_FILES.each { |name, spec| env[name] = "<plist><dict><key>GOOGLE_APP_ID</key><string>1</string><key>BUNDLE_ID</key><string>#{spec[:bundle_id]}</string></dict></plist>" }
  end
end

check "credentials accept PEM or base64 PEM and never expose values through inspect" do
  bundle = Credentials.load!(good_env)
  assert bundle.asc_pem.start_with?("-----BEGIN") && !bundle.inspect.include?("tok")
  assert Credentials.load!(good_env.merge("TESTFLIGHT_ASC_KEY_CONTENT" => [pem].pack("m0"))).asc_pem.include?("PRIVATE KEY")
end

check "blank credentials are reported by name without values" do
  Credentials.required.each do |name|
    error = error_of(Credentials::Error) { Credentials.load!(good_env.merge(name => "  ")) }
    assert error && error.message.include?(name) && !error.message.include?("ABCDE12345"), name
  end
end

check "keychain: failure to read the original list fails before creating anything" do
  runner = Class.new { attr_reader :calls; def initialize = @calls = []; def call(*a) = (@calls << a; ["", false]) }.new
  assert error_of(Keychain::Error) { Keychain.with_temporary(dir: Dir.mktmpdir, runner: runner) { raise "must not run" } }
  assert runner.calls.none? { |c| c.first == "create-keychain" }
end

check "keychain: persisted state lets a fallback script repair a killed run, and is cleared on clean exit" do
  security = Class.new { def call(*a) = [a == ["list-keychains", "-d", "user"] ? "    \"/x/login.keychain-db\"\n" : "", true] }.new
  Dir.mktmpdir do |dir|
    state = File.join(dir, "state")
    Keychain.with_temporary(dir: File.join(dir, "k"), runner: security, state_dir: state) do |path, _|
      assert File.read(File.join(state, "original.txt")) == "/x/login.keychain-db\n" && File.read(File.join(state, "path")).strip == path
    end
    assert !File.exist?(File.join(state, "original.txt")), "state left behind after a clean exit"
  end
end

check "keychain: a cleanup failure while another error is propagating keeps the original error" do
  runner = Class.new do
    def call(*a) = [a == ["list-keychains", "-d", "user"] ? "    \"/x\"\n" : "", a.first != "delete-keychain"]
  end.new
  io = StringIO.new
  error = error_of(RuntimeError) { Keychain.with_temporary(dir: Dir.mktmpdir, runner: runner, warn_io: io) { raise "build failed" } }
  assert error && error.message == "build failed" && io.string.include?("::error::"), io.string
end

check "IPA verification passes the exact expectation and rejects mismatches" do
  info = {
    app: { id: "a.b", version: "1.0", build: "5", team: "T" },
    extensions: [{ id: "a.b.ext", version: "1.0", build: "5", team: "T" }]
  }
  assert IpaVerifier.verify!(info, app_id: "a.b", extension_ids: ["a.b.ext"], team: "T", version: "1.0", build: 5)
  assert error_of(IpaVerifier::Error) { IpaVerifier.verify!(info, app_id: "a.b", extension_ids: [], team: "T", version: "1.0", build: 5) }
  assert error_of(IpaVerifier::Error) { IpaVerifier.verify!(info, app_id: "a.b", extension_ids: ["a.b.ext"], team: "T", version: "1.0", build: 6) }
end

check "package auth restores an absent or existing netrc, even on failure" do
  Dir.mktmpdir do |dir|
    home = File.join(dir, "home")
    FileUtils.mkdir_p(home)
    state = File.join(dir, "state")
    assert error_of(RuntimeError) { PackageAuth.with_netrc(home: home, token: "t", state_dir: state) { raise "boom" } }
    assert !File.exist?(File.join(home, ".netrc")) && !File.exist?(File.join(state, "netrc-installed"))
    File.write(File.join(home, ".netrc"), "keep")
    PackageAuth.with_netrc(home: home, token: "t", state_dir: state) { assert File.read(File.join(home, ".netrc")).include?("password t") }
    assert File.read(File.join(home, ".netrc")) == "keep"
    assert error_of(PackageAuth::Error) { PackageAuth.with_netrc(home: home, token: " ", state_dir: state) { } }
  end
end

check "the fastlane adapter's resolve step unsets credentials in its child environment" do
  source = File.read(File.expand_path("../lib/fastlane_adapter.rb", __dir__))
  assert source.include?("DeploymentPolicy.child_environment") && source.include?("-packageAuthorizationProvider")
end

check "the Fastfile exposes only the guarded beta lane and no local, manual or legacy entry point" do
  source = File.read(File.expand_path("../Fastfile", __dir__))
  lanes = source.scan(/^\s*lane :(\w+)/).flatten
  assert lanes == ["beta"], lanes.inspect
  assert !source.match?(/fetch_testflight_profile|increment_build_number|upload_to_testflight|build_app|ENV\[/), "Fastfile bypasses the pipeline"
  assert source.include?("ReleasePipeline.run")
end

check "no library file reads old-style secret names or environment-controlled readonly" do
  Dir[File.expand_path("../lib/*.rb", __dir__)].each do |file|
    text = File.read(file)
    assert !text.match?(/MATCH_FETCH_READ_ONLY_MODE|APP_STORE_CONNECT_API_KEY_KEY_ID|ENV\["MATCH_PASSWORD"\]/), "legacy reference in #{File.basename(file)}"
  end
end

finish
