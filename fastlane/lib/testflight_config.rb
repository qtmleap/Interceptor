require "fileutils"

module TestFlightConfig
  APP_IDENTIFIER = "jp.qleap.intrcptr".freeze
  TEAM_ID = "5Q94QJ7G98".freeze
  TARGETS = {
    "Interceptor" => APP_IDENTIFIER,
    "PacketTunnel" => "jp.qleap.intrcptr.packet-tunnel"
  }.freeze
  REQUIRED_CREDENTIALS = %w[
    APP_STORE_CONNECT_API_KEY_KEY_ID
    APP_STORE_CONNECT_API_KEY_ISSUER_ID
    APP_STORE_CONNECT_API_KEY_KEY
    MATCH_PASSWORD
    MATCH_GIT_BASIC_AUTHORIZATION
  ].freeze

  def self.validate_credentials!(env)
    missing = REQUIRED_CREDENTIALS.select { |name| env[name].to_s.strip.empty? }
    raise ArgumentError, "Missing credentials: #{missing.join(', ')}" unless missing.empty?
  end

  def self.next_build_number(local:, remote:)
    values = [local, remote].map do |value|
      raise ArgumentError, "Build numbers must be nonnegative integers" unless value.to_s.match?(/\A[0-9]+\z/)
      Integer(value.to_s, 10)
    end
    # Build 31 was uploaded before automatic deployments were introduced.
    [31, *values].max + 1
  end

  def self.signing_targets(profiles)
    TARGETS.each_with_object({}) do |(target, identifier), result|
      profile = profiles[identifier]
      raise ArgumentError, "Missing App Store profile for #{identifier}" if profile.to_s.strip.empty?
      result[target] = profile
    end
  end

  def self.with_upload_home(path)
    original = ENV["HOME"]
    FileUtils.mkdir_p(path, mode: 0700)
    ENV["HOME"] = path
    yield
  ensure
    ENV["HOME"] = original
  end
end
