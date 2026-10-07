require_relative "shared_actions_loader"
app_root = File.expand_path("../..", __dir__) # Consumer path, never a hub inference.
SharedActionsLoader.load!(app_root: app_root)
require File.join(ENV.fetch("QTMLEAP_ACTIONS_ROOT"), "runtime/legacy_loader")
SharedCI.load_legacy("fastlane_adapter", app_root: app_root)
