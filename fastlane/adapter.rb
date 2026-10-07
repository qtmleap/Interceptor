require_relative "lib/shared_actions_loader"
app_root = File.expand_path("..", __dir__)
SharedActionsLoader.load!(app_root: app_root)
runtime = File.join(ENV.fetch("QTMLEAP_ACTIONS_ROOT"), "runtime")
operation = ARGV.shift
abort "Unexpected adapter arguments" unless ARGV.empty?
case operation
when "cleanup"
  require File.join(runtime, "environment")
  environment = SharedCI::Environment.child(ENV)
  environment["RELEASE_WORK"] ||= File.join(ENV.fetch("RUNNER_TEMP"), "release-work")
  exec(environment, "bash", File.join(runtime, "legacy/ci-release-cleanup.sh"), unsetenv_others: true)
when "authorize"
  require_relative "lib/deployment_policy"
  puts "CI deployment target: #{DeploymentPolicy.authorize!(lane: :beta, repo_root: app_root)}"
when "build"
  exec("bash", File.join(runtime, "legacy/ci-release.sh"), app_root)
else
  abort "Unknown adapter operation"
end
