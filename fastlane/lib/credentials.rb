# Validates the TESTFLIGHT_ release credentials entirely in memory. Messages name variables, never values.
require "openssl"
require_relative "release_config"

module Credentials
  class Error < StandardError; end

  # Only the environment-scoped TESTFLIGHT_ names are accepted. Old org/repository names
  # (APP_STORE_CONNECT_API_KEY_*, MATCH_PASSWORD, ...) are deliberately never consulted.
  ASC = %w[TESTFLIGHT_ASC_KEY_ID TESTFLIGHT_ASC_ISSUER_ID TESTFLIGHT_ASC_KEY_CONTENT].freeze
  MATCH = %w[TESTFLIGHT_MATCH_PASSWORD TESTFLIGHT_MATCH_GIT_TOKEN].freeze
  DEPENDENCY = %w[TESTFLIGHT_QUANTUMLEAP_READ_TOKEN].freeze

  Bundle = Struct.new(
    :asc_key_id, :asc_issuer_id, :asc_pem, :match_password, :match_git_token, :quantumleap_token, :extras,
    keyword_init: true
  ) do
    def inspect = "#<Credentials::Bundle [redacted]>"
    alias_method :to_s, :inspect
  end

  module_function

  def required
    ASC + MATCH + DEPENDENCY + ReleaseConfig::EXTRA_SECRETS
  end

  def load!(env)
    missing = required.select { |name| env[name].to_s.strip.empty? }
    raise Error, "Missing release credentials: #{missing.join(', ')}" unless missing.empty?

    Bundle.new(
      asc_key_id: env["TESTFLIGHT_ASC_KEY_ID"].strip,
      asc_issuer_id: env["TESTFLIGHT_ASC_ISSUER_ID"].strip,
      asc_pem: AscKey.pem!(
        key_id: env["TESTFLIGHT_ASC_KEY_ID"], issuer_id: env["TESTFLIGHT_ASC_ISSUER_ID"],
        content: env["TESTFLIGHT_ASC_KEY_CONTENT"]
      ),
      match_password: env["TESTFLIGHT_MATCH_PASSWORD"],
      match_git_token: env["TESTFLIGHT_MATCH_GIT_TOKEN"].strip,
      quantumleap_token: env["TESTFLIGHT_QUANTUMLEAP_READ_TOKEN"].strip,
      extras: ReleaseConfig::EXTRA_SECRETS.to_h { |name| [name, env[name]] }
    )
  end

  # The App Store Connect key id, issuer id and private key must form one coherent, parseable triple.
  module AscKey
    module_function

    def pem!(key_id:, issuer_id:, content:)
      raise Error, "TESTFLIGHT_ASC_KEY_ID is not a ten-character key id." unless key_id.to_s.strip.match?(/\A[A-Z0-9]{10}\z/)
      unless issuer_id.to_s.strip.match?(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
        raise Error, "TESTFLIGHT_ASC_ISSUER_ID is not an issuer UUID."
      end

      pem = decode(content.to_s.strip)
      key = begin
        OpenSSL::PKey.read(pem)
      rescue OpenSSL::PKey::PKeyError
        raise Error, "TESTFLIGHT_ASC_KEY_CONTENT is not a readable private key."
      end
      unless key.is_a?(OpenSSL::PKey::EC) && key.private? && key.group.curve_name == "prime256v1"
        raise Error, "TESTFLIGHT_ASC_KEY_CONTENT is not a P-256 private key."
      end
      pem
    end

    # Accepts the .p8 text itself or its base64 encoding.
    def decode(content)
      return content if content.start_with?("-----BEGIN")

      content.unpack1("m0")
    rescue ArgumentError
      raise Error, "TESTFLIGHT_ASC_KEY_CONTENT is neither PEM nor base64."
    end
  end

  # An app-specific Firebase configuration supplied as a secret. It is installed only into the
  # temporary build copy; neither the content nor any parsed value is printed.
  module PlistSecret
    module_function

    def normalize!(content, bundle_id:, name:)
      text = content.to_s.strip
      text = text.unpack1("m0") unless text.start_with?("<")
      unless text.include?("<plist") && text.match?(%r{<key>GOOGLE_APP_ID</key>\s*<string>[^<]+</string>})
        raise Error, "#{name} is not a Firebase property list."
      end
      found = text[%r{<key>BUNDLE_ID</key>\s*<string>([^<]*)</string>}, 1]
      raise Error, "#{name} is for a different bundle identifier." unless found == bundle_id

      text.end_with?("\n") ? text : "#{text}\n"
    rescue ArgumentError
      raise Error, "#{name} is neither XML nor base64."
    end
  end
end
