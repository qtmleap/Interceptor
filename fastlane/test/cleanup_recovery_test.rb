require_relative "test_helper"
require "open3"

check "a netrc backup is restored even if the marker was never written" do
  Dir.mktmpdir do |dir|
    temp = File.join(dir, "temp")
    work = File.join(temp, "work")
    state = File.join(temp, "release-state")
    user_home = File.join(dir, "home")
    FileUtils.mkdir_p([work, state, user_home])
    File.write(File.join(state, "original.netrc"), "original")
    File.write(File.join(user_home, ".netrc"), "temporary")
    script = File.expand_path("../../scripts/ci-release-cleanup.sh", __dir__)
    _, status = Open3.capture2e({ "RUNNER_TEMP" => temp, "RELEASE_WORK" => work, "HOME" => user_home }, "bash", script)
    assert status.success?
    assert File.read(File.join(user_home, ".netrc")) == "original"
    assert !File.exist?(state)
  end
end

check "failed restoration keeps the recovery state and backup" do
  Dir.mktmpdir do |dir|
    temp = File.join(dir, "temp")
    work = File.join(temp, "work")
    state = File.join(temp, "release-state")
    user_home = File.join(dir, "home")
    bin = File.join(dir, "bin")
    FileUtils.mkdir_p([work, state, user_home, bin])
    File.write(File.join(state, "original.netrc"), "original")
    File.write(File.join(user_home, ".netrc"), "temporary")
    File.write(File.join(bin, "mv"), "#!/bin/sh\nexit 1\n")
    File.chmod(0o755, File.join(bin, "mv"))
    script = File.expand_path("../../scripts/ci-release-cleanup.sh", __dir__)
    _, status = Open3.capture2e({ "RUNNER_TEMP" => temp, "RELEASE_WORK" => work, "HOME" => user_home,
                                "PATH" => "#{bin}:#{ENV['PATH']}" }, "bash", script)
    assert !status.success?
    assert File.read(File.join(state, "original.netrc")) == "original"
    assert File.exist?(state)
    assert !File.exist?(work)
  end
end
finish
