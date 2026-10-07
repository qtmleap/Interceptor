require_relative "test_helper"
require_relative "../lib/deployment_policy"
require "yaml"

check "the Fastfile exposes only the guarded beta lane" do
  source = File.read(File.expand_path("../Fastfile", __dir__))
  assert source.scan(/^\s*lane :(\w+)/).flatten == ["beta"]
  assert !source.match?(/fetch_testflight_profile|increment_build_number|upload_to_testflight|build_app|ENV\[/)
  assert source.include?("ReleasePipeline.run")
end

check "all configured required checks are actual pull request jobs" do
  root = File.expand_path("../..", __dir__)
  ReleaseConfig::REQUIRED.each do |path, checks|
    workflow = YAML.safe_load(File.read(File.join(root, path)), aliases: false)
    triggers = workflow.fetch("on") { workflow.fetch(true) }
    assert triggers.key?("pull_request"), path
    jobs = workflow.fetch("jobs").values.map { |job| job.fetch("name") }
    assert (checks - jobs).empty?, "missing checks in #{path}"
  end
end

check "the local deployment adapter retains credential-free independent cleanup" do
  root = File.expand_path("../..", __dir__)
  source = File.read(File.join(root, "fastlane/adapter.rb"))
  assert source.index('when "cleanup"') < source.index('when "authorize"')
  assert source.include?("SharedCI::Environment.child")
  workflow = YAML.safe_load(File.read(File.join(root, ".github/workflows/testflight.yaml")), aliases: false)
  steps = workflow.fetch("jobs").fetch("deploy").fetch("steps")
  cleanup = steps.find { |step| step.dig("with", "operation") == "cleanup" }
  record = steps.find { |step| step["uses"]&.include?("/release-record@") }
  assert cleanup.fetch("if") == "always()" && record.fetch("if") == "always()"
  assert cleanup.fetch("env", {}).values.none? { |value| value.to_s.include?("secrets.") }
  assert record.dig("with", "expected-source-sha") == '${{ needs.verify.outputs.sha }}'
  assert record.dig("with", "if-no-files-found") == "ignore"
end
check "all shared steps resolve the app checkout root" do
  root = File.expand_path("../..", __dir__)
  workflow = YAML.safe_load(File.read(File.join(root, ".github/workflows/testflight.yaml")), aliases: false)
  workflow.fetch("jobs").each_value do |job|
    steps = job.fetch("steps")
    checkout = steps.find { |step| step["uses"]&.start_with?("actions/checkout@") }
    app_path = checkout.fetch("with", {}).fetch("path", ".")
    steps.select { |step| step["uses"]&.start_with?("qtmleap/actions/") }.each do |step|
      assert step.fetch("with", {}).fetch("repo-root", ".") == app_path, step.fetch("uses")
    end
  end
end
finish
