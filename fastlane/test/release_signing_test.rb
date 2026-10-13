# Run with `ruby fastlane/test/release_signing_test.rb`. Plain asserts, no gems, no Xcode.

require_relative "../lib/release_signing"
require "tmpdir"

$failures = 0

def check(name)
  yield
  puts "ok   #{name}"
rescue StandardError, ScriptError => e
  $failures += 1
  puts "FAIL #{name}: #{e.class}: #{e.message}"
end

def assert(cond, msg = "assertion failed")
  raise msg unless cond
end

def assert_raises(klass, pattern = nil)
  yield
  raise "expected #{klass}"
rescue klass => e
  assert pattern.nil? || e.message.match?(pattern), "message #{e.message.inspect} !~ #{pattern.inspect}"
end

# Minimal stand-ins for the Xcodeproj API surface used (native_targets / name / build_configurations).
Config = Struct.new(:name, :build_settings)
Target = Struct.new(:name, :build_configurations)
Project = Struct.new(:native_targets)

def target(name, style: "Manual", profile: "p", configs: %w[Debug Release])
  Target.new(name, configs.map { |c| Config.new(c, { "CODE_SIGN_STYLE" => style, "PROVISIONING_PROFILE_SPECIFIER" => profile }) })
end

# Fake `security`: records argv, fails on demand.
class FakeSecurity
  attr_reader :calls
  def initialize(fail_on: nil, list: "    \"/Users/x/Library/Keychains/login.keychain-db\"\n    \"/Library/Keychains/System.keychain\"\n")
    @calls = []
    @fail_on = fail_on
    @list = list
  end

  def to_proc
    method(:call).to_proc
  end

  def call(*argv)
    @calls << argv
    return ["", false] if @fail_on && argv[1] == @fail_on
    return [@list, true] if argv[1] == "list-keychains" && !argv.include?("-s")
    ["", true]
  end

  def subcommands
    @calls.map { |c| c[1] }
  end
end

ORIGINAL = ["/Users/x/Library/Keychains/login.keychain-db", "/Library/Keychains/System.keychain"].freeze

# ---- signing target resolution

check "resolves requested targets by Xcodeproj target name" do
  project = Project.new([target("Interceptor"), target("PacketTunnel"), target("InterceptorTests")])
  resolved = ReleaseSigning.resolve_targets(project, %w[Interceptor PacketTunnel])
  assert resolved.keys == %w[Interceptor PacketTunnel], resolved.keys.inspect
end

check "the product name packet-tunnel is not a target and fails fast" do
  project = Project.new([target("Interceptor"), target("PacketTunnel")])
  assert_raises(ReleaseSigning::Error, /not found.*packet-tunnel.*Available targets: Interceptor, PacketTunnel/) do
    ReleaseSigning.resolve_targets(project, %w[Interceptor packet-tunnel])
  end
end

check "verify_modified passes only when style is Manual and the profile is applied" do
  project = Project.new([target("Interceptor", profile: "app"), target("PacketTunnel", profile: "tun")])
  assert ReleaseSigning.verify_modified(project, { "Interceptor" => "app", "PacketTunnel" => "tun" })
end

check "verify_modified fails when a target was not modified" do
  project = Project.new([target("Interceptor", profile: "app"), target("PacketTunnel", style: "Automatic", profile: nil)])
  assert_raises(ReleaseSigning::Error, /not modified.*PacketTunnel \(Debug\): CODE_SIGN_STYLE.*PacketTunnel \(Release\)/) do
    ReleaseSigning.verify_modified(project, { "Interceptor" => "app", "PacketTunnel" => "tun" })
  end
end

check "verify_modified fails on a stale profile and on a missing target" do
  project = Project.new([target("Interceptor", profile: "old")])
  assert_raises(ReleaseSigning::Error, /profile was not applied/) { ReleaseSigning.verify_modified(project, { "Interceptor" => "new" }) }
  assert_raises(ReleaseSigning::Error, /PacketTunnel/) { ReleaseSigning.verify_modified(project, { "PacketTunnel" => "tun" }) }
end

check "verify_modified honours a configuration filter and rejects an empty match" do
  project = Project.new([target("App", profile: "p")])
  project.native_targets.first.build_configurations.first.build_settings["CODE_SIGN_STYLE"] = "Automatic" # Debug only
  assert ReleaseSigning.verify_modified(project, { "App" => "p" }, configurations: ["Release"])
  assert_raises(ReleaseSigning::Error, /no matching build configuration/) do
    ReleaseSigning.verify_modified(project, { "App" => "p" }, configurations: ["Beta"])
  end
end

# ---- keychain isolation

check "keychain is created, unlocked, searched, yielded, then restored and deleted" do
  sec = FakeSecurity.new
  yielded = nil
  ReleaseSigning.with_isolated_keychain(runner: sec.to_proc, password: "pw", keychains_dir: "/k") { |kc| yielded = kc }
  assert yielded.password == "pw"
  assert yielded.path.start_with?("/k/release-") && yielded.path.end_with?(".keychain-db"), yielded.path
  assert sec.subcommands == %w[list-keychains create-keychain set-keychain-settings unlock-keychain list-keychains list-keychains delete-keychain], sec.subcommands.inspect
  search = sec.calls[4]
  assert search == ["security", "list-keychains", "-d", "user", "-s", yielded.path, *ORIGINAL], search.inspect
  assert sec.calls[5] == ["security", "list-keychains", "-d", "user", "-s", *ORIGINAL], "search list not restored"
  assert sec.calls.last == ["security", "delete-keychain", yielded.path]
end

check "the isolated keychain never becomes the default" do
  sec = FakeSecurity.new
  ReleaseSigning.with_isolated_keychain(runner: sec.to_proc, password: "pw", keychains_dir: "/k") { }
  assert sec.calls.none? { |c| c.include?("default-keychain") }, "default-keychain was touched"
end

check "cleanup runs when the block raises, and the original error survives" do
  sec = FakeSecurity.new
  assert_raises(RuntimeError, /build exploded/) do
    ReleaseSigning.with_isolated_keychain(runner: sec.to_proc, password: "pw", keychains_dir: "/k") { raise "build exploded" }
  end
  assert sec.subcommands.last(2) == %w[list-keychains delete-keychain], sec.subcommands.inspect
end

check "cleanup failure never masks the block's exception" do
  sec = FakeSecurity.new(fail_on: "delete-keychain")
  assert_raises(RuntimeError, /boom/) do
    ReleaseSigning.with_isolated_keychain(runner: sec.to_proc, password: "pw", keychains_dir: "/k") { raise "boom" }
  end
end

check "cleanup failure is reported when the block succeeded" do
  sec = FakeSecurity.new(fail_on: "delete-keychain")
  assert_raises(ReleaseSigning::Error, /cleanup failed: delete keychain/) do
    ReleaseSigning.with_isolated_keychain(runner: sec.to_proc, password: "pw", keychains_dir: "/k") { }
  end
end

check "a failed setup step still deletes the keychain and restores the list, without running the block" do
  sec = FakeSecurity.new(fail_on: "unlock-keychain")
  ran = false
  assert_raises(ReleaseSigning::Error, /unlock-keychain failed/) do
    ReleaseSigning.with_isolated_keychain(runner: sec.to_proc, password: "pw", keychains_dir: "/k") { ran = true }
  end
  assert !ran, "block ran"
  assert sec.subcommands.last(2) == %w[list-keychains delete-keychain], sec.subcommands.inspect
end

check "failing to read the search list creates and deletes nothing" do
  sec = FakeSecurity.new(fail_on: "list-keychains")
  assert_raises(ReleaseSigning::Error) { ReleaseSigning.with_isolated_keychain(runner: sec.to_proc, password: "pw") { } }
  assert sec.subcommands == %w[list-keychains], sec.subcommands.inspect
end

check "each run uses a fresh keychain path and a random password by default" do
  paths = []
  passwords = []
  2.times do
    ReleaseSigning.with_isolated_keychain(runner: FakeSecurity.new.to_proc, keychains_dir: "/k") do |kc|
      paths << kc.path
      passwords << kc.password
    end
  end
  assert paths.uniq.size == 2 && passwords.uniq.size == 2, "not unique"
  assert passwords.all? { |p| p.match?(/\A[0-9a-f]{48}\z/) }, "password is not 24 random bytes"
end

check "security failure messages never contain the password" do
  sec = FakeSecurity.new(fail_on: "create-keychain")
  begin
    ReleaseSigning.with_isolated_keychain(runner: sec.to_proc, password: "s3cr3t-pw", keychains_dir: "/k") { }
    raise "expected failure"
  rescue ReleaseSigning::Error => e
    assert !e.message.include?("s3cr3t-pw"), "password leaked"
  end
end

# ---- match wiring

check "match receives the isolated keychain explicitly and stays read-only" do
  kc = ReleaseSigning::Keychain.new("/k/release-x.keychain-db", "pw")
  opts = ReleaseSigning.match_options(api_key: :key, app_identifier: ["a", "b"], keychain: kc)
  assert opts[:keychain_name] == "/k/release-x.keychain-db" && opts[:keychain_password] == "pw", opts.inspect
  assert opts[:readonly] == true && opts[:type] == "appstore" && opts[:app_identifier] == %w[a b]
end

check "match without a keychain is refused rather than falling back to a default" do
  assert_raises(ReleaseSigning::Error, /isolated keychain/) { ReleaseSigning.match_options(api_key: :k, app_identifier: "a", keychain: nil) }
end

# ---- Fastfile wiring (static): the lane text must keep the guarantees the helpers provide

FASTFILE = File.read(File.expand_path("../Fastfile", __dir__))

check "Fastfile no longer calls setup_ci (its default keychain has an empty password)" do
  assert !FASTFILE.match?(/^\s*setup_ci\b/), "setup_ci still present"
end

check "Fastfile wires match through ReleaseSigning and never sets a default keychain" do
  assert FASTFILE.include?("ReleaseSigning.match_options"), "match is not wired to the isolated keychain"
  assert FASTFILE.include?("ReleaseSigning.with_isolated_keychain"), "no isolated keychain"
  assert !FASTFILE.match?(/default-keychain|set_default:\s*true|create_keychain/), "default keychain handling present"
end

check "Fastfile never expires previous builds" do
  assert FASTFILE.include?("expire_previous_builds: false"), "expire_previous_builds is not false"
  assert !FASTFILE.include?("expire_previous_builds: true")
end

puts($failures.zero? ? "all passed" : "#{$failures} failed")
exit($failures.zero? ? 0 : 1)
