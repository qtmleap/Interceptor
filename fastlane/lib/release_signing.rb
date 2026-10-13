# Signing helpers for the CI beta lane, kept free of fastlane so `ruby fastlane/test/release_signing_test.rb`
# can exercise them with mocks (no Xcode, keychain or network involved).

require "open3"
require "securerandom"

module ReleaseSigning
  class Error < StandardError; end

  # Runs a command given as an argv array. Returns [output, success]. Arguments are never
  # interpolated into a shell and never echoed back in error messages (one carries a password).
  SECURITY_RUNNER = lambda do |*argv|
    output, status = Open3.capture2e(*argv)
    [output, status.success?]
  end

  # ---- signing targets -------------------------------------------------------------------

  # Resolves requested target names against the project's native targets (Xcodeproj API:
  # `project.native_targets`, `target.name`). The product name is not a target name, so a
  # missing target fails here instead of silently signing nothing.
  def self.resolve_targets(project, requested)
    by_name = project.native_targets.to_h { |target| [target.name, target] }
    missing = requested - by_name.keys
    unless missing.empty?
      raise Error, "Signing targets not found in project: #{missing.join(', ')}. " \
                   "Available targets: #{by_name.keys.sort.join(', ')}"
    end
    requested.to_h { |name| [name, by_name.fetch(name)] }
  end

  # Fails unless every requested target (in the requested configurations, or all when nil)
  # now carries manual signing with the expected profile. `expected` maps target name => profile.
  def self.verify_modified(project, expected, configurations: nil)
    targets = resolve_targets(project, expected.keys)
    problems = []
    targets.each do |name, target|
      configs = target.build_configurations.select { |c| configurations.nil? || configurations.include?(c.name) }
      problems << "#{name}: no matching build configuration" if configs.empty?
      configs.each do |config|
        settings = config.build_settings
        problems << "#{name} (#{config.name}): CODE_SIGN_STYLE is not Manual" unless settings["CODE_SIGN_STYLE"] == "Manual"
        unless settings["PROVISIONING_PROFILE_SPECIFIER"] == expected.fetch(name)
          problems << "#{name} (#{config.name}): provisioning profile was not applied"
        end
      end
    end
    raise Error, "Signing targets were not modified: #{problems.join('; ')}" unless problems.empty?
    true
  end

  # ---- isolated keychain -----------------------------------------------------------------

  Keychain = Struct.new(:path, :password)

  # Creates a keychain for this run only, with a random password, puts it first in the user
  # search list (xcodebuild/codesign find identities through it) and NEVER makes it the default.
  # Whatever the block does, the search list is put back and the keychain is deleted.
  def self.with_isolated_keychain(runner: SECURITY_RUNNER, password: SecureRandom.hex(24),
                                  keychains_dir: File.join(Dir.home, "Library", "Keychains"))
    name = "release-#{SecureRandom.hex(8)}.keychain"
    path = File.join(keychains_dir, "#{name}-db")
    original = nil
    attempted_create = false
    in_flight = nil
    begin
      out, ok = runner.call("security", "list-keychains", "-d", "user")
      raise Error, "security list-keychains failed" unless ok
      original = out.lines.map { |l| l.strip.delete('"') }.reject(&:empty?)

      attempted_create = true
      run!(runner, "create-keychain", "security", "create-keychain", "-p", password, name)
      run!(runner, "set-keychain-settings", "security", "set-keychain-settings", "-lut", "21600", path)
      run!(runner, "unlock-keychain", "security", "unlock-keychain", "-p", password, path)
      run!(runner, "list-keychains", "security", "list-keychains", "-d", "user", "-s", path, *original)
      yield Keychain.new(path, password)
    rescue Exception => e # rubocop:disable Lint/RescueException
      in_flight = e
      raise
    ensure
      failures = []
      if original
        _, ok = runner.call("security", "list-keychains", "-d", "user", "-s", *original)
        failures << "restore keychain search list" unless ok
      end
      if attempted_create
        _, ok = runner.call("security", "delete-keychain", path)
        failures << "delete keychain" unless ok
      end
      # Never replace an exception already in flight with a cleanup failure.
      raise Error, "Keychain cleanup failed: #{failures.join(', ')}" if !failures.empty? && in_flight.nil?
    end
  end

  def self.run!(runner, label, *argv)
    _, ok = runner.call(*argv)
    raise Error, "security #{label} failed" unless ok
  end
  private_class_method :run!

  # ---- match -----------------------------------------------------------------------------

  # Arguments for `match`: always read-only, always the explicit isolated keychain.
  def self.match_options(api_key:, app_identifier:, keychain:)
    raise Error, "match requires the isolated keychain" if keychain.nil?
    {
      api_key: api_key,
      type: "appstore",
      app_identifier: app_identifier,
      readonly: true,
      keychain_name: keychain.path,
      keychain_password: keychain.password
    }
  end
end
