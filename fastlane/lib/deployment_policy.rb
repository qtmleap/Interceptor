require_relative "shared_actions_loader"
app_root = File.expand_path("../..", __dir__) # Consumer path, never a hub inference.
SharedActionsLoader.load!(app_root: app_root)
require File.join(ENV.fetch("QTMLEAP_ACTIONS_ROOT"), "runtime/legacy_loader")
SharedCI.load_legacy("deployment_policy", app_root: app_root)

if __FILE__ == $PROGRAM_NAME
  begin
    puts "CI deployment target: #{DeploymentPolicy.authorize!(lane: :beta, repo_root: app_root)}"
  rescue DeploymentPolicy::Error => error
    warn error.message
    exit 1
  end
end
