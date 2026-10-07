# A dedicated per-run keychain. The user's keychain search list is restored and the keychain
# deleted on every exit path; a cleanup failure is reported instead of being swallowed.
require "fileutils"
require "open3"
require "securerandom"

module Keychain
  class Error < StandardError; end

  # Runs `security`; injectable so tests need no Mac.
  class SecurityRunner
    def call(*args)
      out, status = Open3.capture2e("security", *args)
      [out, status.success?]
    rescue SystemCallError => error
      [error.message, false]
    end
  end

  module_function

  def parse_list(output)
    output.lines.filter_map { |line| line[/"(.*)"/, 1] }.reject(&:empty?)
  end

  # `state_dir` persists the original list so a fallback script can restore it after a crash.
  def with_temporary(dir:, runner: SecurityRunner.new, state_dir: nil, warn_io: $stderr)
    FileUtils.mkdir_p(dir, mode: 0o700)
    path = File.join(dir, "release.keychain-db")
    password = SecureRandom.hex(24)
    out, ok = runner.call("list-keychains", "-d", "user")
    raise Error, "Cannot read the current keychain search list." unless ok

    original = parse_list(out)
    if state_dir
      FileUtils.mkdir_p(state_dir, mode: 0o700)
      File.write(File.join(state_dir, "original.txt"), original.join("\n") + "\n")
      File.write(File.join(state_dir, "path"), path + "\n")
    end
    failure = nil
    begin
      step!(runner, "create", "create-keychain", "-p", password, path)
      step!(runner, "settings", "set-keychain-settings", "-lut", "7200", path)
      step!(runner, "unlock", "unlock-keychain", "-p", password, path)
      step!(runner, "list", "list-keychains", "-d", "user", "-s", path, *original)
      yield path, password
    rescue Exception => error # rubocop:disable Lint/RescueException
      failure = error
      raise
    ensure
      problems = cleanup(runner, path, original)
      clear_state(state_dir) if state_dir && problems.empty?
      unless problems.empty?
        message = "Keychain cleanup failed: #{problems.join(', ')}"
        raise Error, message unless failure

        warn_io.puts("::error::#{message}")
      end
    end
  end

  # The state files only exist to repair an interrupted run; a clean exit leaves nothing to repair.
  def clear_state(state_dir)
    FileUtils.rm_f([File.join(state_dir, "original.txt"), File.join(state_dir, "path")])
  end

  def step!(runner, label, *args)
    _, ok = runner.call(*args)
    raise Error, "Keychain #{label} step failed." unless ok
  end

  def cleanup(runner, path, original)
    problems = []
    _, ok = runner.call("list-keychains", "-d", "user", "-s", *original)
    problems << "restore search list" unless ok
    _, ok = runner.call("delete-keychain", path)
    problems << "delete keychain" unless ok
    FileUtils.rm_f(path)
    problems << "keychain file remains" if File.exist?(path)
    problems
  end
end
