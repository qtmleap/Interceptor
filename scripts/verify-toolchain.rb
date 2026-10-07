require_relative "../fastlane/lib/shared_actions_loader"
app_root = File.expand_path("..", __dir__)
SharedActionsLoader.load!(app_root: app_root)
root = ENV.fetch("QTMLEAP_ACTIONS_ROOT")
exec({ "GITHUB_WORKSPACE" => app_root, "SHARED_REPO_ROOT" => ".",
       "SHARED_ACTION_ROOT" => root,
       "SHARED_XCODE_VERSION" => ENV.fetch("EXPECTED_XCODE_MAJOR", "27"),
       "SHARED_DEVELOPER_DIR" => ENV.fetch("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer") },
     "bash", File.join(root, "runtime/apple-toolchain.sh"))
