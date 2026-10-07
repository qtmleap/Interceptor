# Private Swift package credentials exist only as a temporary ~/.netrc for the resolution step.
# They are never placed in the environment, and the previous ~/.netrc is restored afterwards.
# `state_dir` holds the backup and an `installed` marker so scripts/ci-release-cleanup.sh can
# undo this even if the Ruby process is killed.
require "fileutils"

module PackageAuth
  class Error < StandardError; end

  module_function

  def with_netrc(home:, token:, state_dir:)
    raise Error, "No dependency token was provided." if token.to_s.strip.empty?

    path = File.join(home, ".netrc")
    backup = File.join(state_dir, "original.netrc")
    marker = File.join(state_dir, "netrc-installed")
    FileUtils.mkdir_p(state_dir, mode: 0o700)
    had_original = File.exist?(path) || File.symlink?(path)
    File.write(marker, had_original ? "original-pending\n" : "empty\n")
    FileUtils.mv(path, backup) if had_original
    begin
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write("machine github.com\n  login x-access-token\n  password #{token.strip}\n")
      end
      yield
    ensure
      FileUtils.rm_f(path)
      FileUtils.mv(backup, path) if had_original
      FileUtils.rm_f(marker)
    end
  end
end
