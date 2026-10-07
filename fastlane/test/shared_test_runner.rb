require_relative "../lib/shared_actions_loader"
module SharedTestRunner
  def self.run(name)
    app_root = File.expand_path("../..", __dir__)
    SharedActionsLoader.load!(app_root: app_root)
    ENV["SHARED_CI_TEST_APP_ROOT"] = app_root
    load File.join(ENV.fetch("QTMLEAP_ACTIONS_ROOT"), "runtime/test/legacy", "#{name}_test.rb")
  end
end
