require_relative "shared_actions_loader"
require_relative "deployment_policy"
SharedActionsLoader.load!(app_root: File.expand_path("../..", __dir__))
require File.join(ENV.fetch("QTMLEAP_ACTIONS_ROOT"), "runtime/compatibility")
MergeVerifier = SharedCI.merge_wrapper(
  error_class: DeploymentPolicy::Error,
  config: { repository: DeploymentPolicy::REPOSITORY, branches: DeploymentPolicy::BRANCHES,
            workflow: DeploymentPolicy::WORKFLOW, required_checks: ReleaseConfig::REQUIRED,
            record_only_paths: [DeploymentPolicy::SHIPPED_RECORD] }
)
if __FILE__ == $PROGRAM_NAME
  begin
    result = MergeVerifier.new(env: ENV.to_h,
      event: JSON.parse(File.read(ENV.fetch("GITHUB_EVENT_PATH"))),
      api: MergeVerifier::Api.new(token: ENV["GITHUB_TOKEN"]), git: MergeVerifier::Git.new(Dir.pwd)).call
    MergeVerifier.write_output(ENV.fetch("GITHUB_OUTPUT"), **result)
  rescue MergeVerifier::Error, JSON::ParserError, KeyError, SystemCallError
    warn "Merge verification failed"
    exit 1
  end
end
