# Compares what the archived IPA actually contains with what was intended, before upload.
# `inspect_ipa` (Mac only) produces the data; `verify!` is pure and tested on fixtures.
require "fileutils"
require "json"
require "open3"
require "tmpdir"

module IpaVerifier
  class Error < StandardError; end

  # inspection: { app: {id:, version:, build:, team:}, extensions: [{id:, version:, build:, team:}] }
  def self.verify!(inspection, app_id:, extension_ids:, team:, version:, build:)
    app = inspection[:app] or raise Error, "The IPA has no app bundle."
    raise Error, "The IPA bundle identifier is #{app[:id].inspect}, not #{app_id}." unless app[:id] == app_id
    raise Error, "The IPA version is #{app[:version].inspect}, not #{version}." unless app[:version] == version
    raise Error, "The IPA build number is #{app[:build].inspect}, not #{build}." unless app[:build] == build.to_s
    raise Error, "The IPA is signed by team #{app[:team].inspect}, not #{team}." unless app[:team] == team

    found = inspection[:extensions].to_a.map { |extension| extension[:id] }.sort
    unless found == extension_ids.sort
      raise Error, "The IPA extensions #{found.inspect} differ from #{extension_ids.sort.inspect}."
    end
    inspection[:extensions].each do |extension|
      raise Error, "Extension #{extension[:id]} has build #{extension[:build].inspect}." unless extension[:build] == build.to_s
      raise Error, "Extension #{extension[:id]} is signed by another team." unless extension[:team] == team
      raise Error, "Extension #{extension[:id]} has no version." if extension[:version].to_s.empty?
    end
    true
  end

  def self.capture!(*command)
    out, status = Open3.capture2e(*command)
    raise Error, "#{command.first} failed." unless status.success?

    out
  rescue SystemCallError
    raise Error, "#{command.first} is unavailable."
  end

  def self.bundle_info(path)
    info = JSON.parse(capture!("plutil", "-convert", "json", "-o", "-", File.join(path, "Info.plist")))
    signature = Open3.capture2e("codesign", "-dv", "--verbose=2", path)
    capture!("codesign", "--verify", "--strict", path)
    team = signature.first[/^TeamIdentifier=(\S+)/, 1]
    { id: info["CFBundleIdentifier"], version: info["CFBundleShortVersionString"],
      build: info["CFBundleVersion"], team: team }
  end

  def self.inspect_ipa(ipa)
    Dir.mktmpdir("ipa-inspect-", ENV.fetch("RELEASE_WORK")) do |dir|
      capture!("unzip", "-q", ipa, "-d", dir)
      apps = Dir[File.join(dir, "Payload", "*.app")]
      raise Error, "The IPA must contain exactly one app." unless apps.length == 1

      { app: bundle_info(apps.first),
        extensions: Dir[File.join(apps.first, "PlugIns", "*.appex")].sort.map { |path| bundle_info(path) } }
    end
  end
end
