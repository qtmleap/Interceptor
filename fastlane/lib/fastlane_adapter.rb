# The only file that touches fastlane actions and Apple tooling. It is handed the Fastfile context
# (`fl`) so release_pipeline.rb can be tested with a fake. Secrets arrive as arguments, never ENV.
require "open3"
require_relative "release_config"
require_relative "deployment_policy"
require_relative "ipa_verifier"

class FastlaneAdapter
  class Error < StandardError; end

  def initialize(fl)
    @fl = fl
  end

  # The ASC key is passed as in-memory content. No key file is written and none is read from ENV.
  def asc_api_key(key_id:, issuer_id:, pem:)
    @fl.app_store_connect_api_key(
      key_id: key_id, issuer_id: issuer_id, key_content: pem, is_key_content_base64: false, in_house: false
    )
  end

  # Read-only, unconditionally: certificates and profiles are never created, renewed or revoked.
  def match_signing(api_key:, app_identifiers:, git_url:, keychain:, keychain_password:)
    @fl.match(
      api_key: api_key, type: "appstore", app_identifier: app_identifiers, git_url: git_url,
      readonly: true, force: false, force_for_new_devices: false,
      keychain_name: keychain, keychain_password: keychain_password
    )
    @fl.lane_context[Fastlane::Actions::SharedValues::MATCH_PROVISIONING_PROFILE_MAPPING]
  end

  def marketing_version(project:, target:)
    @fl.get_version_number(xcodeproj: project, target: target)
  end

  def remote_build_number(api_key:, app_identifier:, version:)
    @fl.latest_testflight_build_number(
      api_key: api_key, app_identifier: app_identifier, version: version, initial_build_number: 0
    )
  end

  # Target-specific manual signing keeps Swift package resource bundles unsigned by a global profile.
  def set_signing(project:, target:, profile:, team:)
    @fl.update_code_signing_settings(
      path: project, targets: [target], build_configurations: ["Release"], use_automatic_signing: false,
      team_id: team, code_sign_identity: "Apple Distribution", profile_name: profile
    )
  end

  def resolve_packages(project:, scheme:, packages:)
    run!(
      "xcodebuild", "-resolvePackageDependencies", "-project", project, "-scheme", scheme,
      "-clonedSourcePackagesDirPath", packages, "-packageAuthorizationProvider", "netrc",
      "-onlyUsePackageVersionsFromResolvedFile", "-skipPackagePluginValidation"
    )
  end

  def archive(project:, scheme:, profiles:, packages:, derived_data:, output:, team:)
    @fl.build_app(
      project: project, scheme: scheme, configuration: "Release", clean: true,
      export_method: "app-store", export_team_id: team,
      export_options: { signingStyle: "manual", provisioningProfiles: profiles },
      cloned_source_packages_path: packages, derived_data_path: derived_data,
      output_directory: output, archive_path: File.join(output, "#{scheme}.xcarchive"),
      buildlog_path: File.join(output, "logs"), skip_package_dependencies_resolution: true,
      xcargs: "-disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackagePluginValidation"
    )
  end

  def inspect_ipa(ipa)
    IpaVerifier.inspect_ipa(ipa)
  end

  def upload(api_key:, ipa:, app_identifier:, options:)
    @fl.upload_to_testflight(
      api_key: api_key, app_identifier: app_identifier, ipa: ipa, demo_account_required: false,
      **options
    )
  end

  private

  def run!(*command)
    unset = DeploymentPolicy.child_environment
    _, status = Open3.capture2e(unset, *command)
    raise Error, "#{command.first} #{command[1]} failed." unless status.success?
  end
end
