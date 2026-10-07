require_relative "test_helper"
require_relative "../lib/deployment_policy"

check "authorization Git children receive no signing or upload credentials" do
  Dir.mktmpdir do |dir|
    path = File.join(dir, "git")
    File.write(path, "#!#{RbConfig.ruby}\nrequire 'json'\nputs JSON.generate(ENV.keys.grep(/^(TESTFLIGHT_|ASC_|MATCH_|GITHUB_TOKEN|RELEASE_SOURCE_READ_TOKEN)/))\n")
    File.chmod(0o755, path)
    with_environment("PATH" => "#{dir}:#{ENV['PATH']}", "TESTFLIGHT_ASC_KEY_CONTENT" => "fixture-key",
                     "MATCH_PASSWORD" => "fixture-password", "GITHUB_TOKEN" => "fixture-job",
                     "RELEASE_SOURCE_READ_TOKEN" => "fixture-source") do
      result = JSON.parse(DeploymentPolicy.git_output(dir, "rev-parse", "HEAD"))
      assert result.empty?, result.inspect
      result, status = Open3.capture2e(DeploymentPolicy.child_environment, path)
      assert status.success? && JSON.parse(result).empty?
    end
  end
end

check "private source authentication is scoped to the live-tip Git query" do
  Dir.mktmpdir do |dir|
    capture = File.join(dir, "capture.json")
    path = File.join(dir, "git")
    File.write(path, <<~RB)
      #!#{RbConfig.ruby}
      require "json"
      File.write(#{capture.inspect}, JSON.generate(ENV.to_h.select { |k, _| k.start_with?("GIT_CONFIG_") || k.start_with?("TESTFLIGHT_") || k == "RELEASE_SOURCE_READ_TOKEN" }))
      puts "#{MERGE}\\trefs/heads/develop"
    RB
    File.chmod(0o755, path)
    with_environment("PATH" => "#{dir}:#{ENV['PATH']}", "TESTFLIGHT_ASC_KEY_CONTENT" => "fixture-key",
                     "RELEASE_SOURCE_READ_TOKEN" => "fixture-source", "GIT_CONFIG_COUNT" => "2",
                     "GIT_CONFIG_VALUE_1" => "old-secret") do
      assert DeploymentPolicy.branch_sha(dir, branch: "develop", source_token: "fixture-source") == MERGE
      env = JSON.parse(File.read(capture))
      assert env["GIT_CONFIG_COUNT"] == "1"
      assert env["GIT_CONFIG_KEY_0"] == "http.https://github.com/.extraheader"
      assert env["GIT_CONFIG_VALUE_0"] == "AUTHORIZATION: basic #{['x-access-token:fixture-source'].pack('m0')}"
      assert !env.key?("GIT_CONFIG_VALUE_1") && !env.key?("TESTFLIGHT_ASC_KEY_CONTENT") && !env.key?("RELEASE_SOURCE_READ_TOKEN")
    end
  end
end
finish
