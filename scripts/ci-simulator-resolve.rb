require_relative "../fastlane/lib/package_auth"
require_relative "../fastlane/lib/deployment_policy"

# 依存解決が終わったら認証を戻し、ビルドスクリプトへ読み取り資格情報を残さない。
token = ENV.fetch("QUANTUMLEAP_READ_TOKEN")
raise "QuantumLeap read token is missing" if token.empty?
PackageAuth.with_netrc(home: Dir.home, token: token,
                       state_dir: File.join(ENV.fetch("RUNNER_TEMP"), "release-state")) do
  DeploymentPolicy.without_credentials do
    ok = system("xcodebuild", "-resolvePackageDependencies", "-scmProvider", "system",
                "-project", "Interceptor.xcodeproj", "-scheme", "Interceptor",
                "-clonedSourcePackagesDirPath", ENV.fetch("PLL_SOURCE_PACKAGES_PATH"),
                "-packageAuthorizationProvider", "netrc", "-onlyUsePackageVersionsFromResolvedFile",
                "-skipPackagePluginValidation")
    raise "Package resolution failed" unless ok
  end
end
