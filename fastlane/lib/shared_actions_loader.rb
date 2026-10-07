# Consumer trust anchor: review this small loader locally, do not download/eval it.
require "json"
require "digest"
require "fileutils"
require "tmpdir"
require "open3"

module SharedActionsLoader
  module_function
  def load!(app_root:)
    app = File.realpath(app_root)
    lock = JSON.parse(File.read(File.join(app, ".github/shared-actions.lock.json")))
    revision = lock.fetch("revision")
    raise "Invalid revision" unless revision.is_a?(String) && revision.match?(/\A[0-9a-f]{40}\z/) && revision != "0" * 40
    expected = ENV["QTMLEAP_ACTIONS_REVISION"]
    raise "Expected revision mismatch" if expected && expected != revision
    root = ENV["QTMLEAP_ACTIONS_ROOT"]
    if root.nil? || root.empty?
      temp = File.realpath(ENV.fetch("RUNNER_TEMP", Dir.tmpdir))
      raise "Runtime temp inside source" if temp == app || temp.start_with?(app + "/")
      cache = File.join(temp, "qtmleap-actions-#{revision}")
      # Never repair or silently replace a tampered cache.
      unless File.exist?(cache)
        Dir.mktmpdir("shared-bootstrap-", temp) do |stage|
          env = ENV.keys.to_h { |key| [key, nil] }.merge("PATH" => ENV.fetch("PATH"), "HOME" => stage,
            "GIT_CONFIG_NOSYSTEM" => "1", "GIT_TERMINAL_PROMPT" => "0")
          git = lambda do |*args|
            out, status = Open3.capture2e(env, "git", "-C", stage, *args, unsetenv_others: true)
            raise "Public runtime bootstrap failed" unless status.success?
            out
          end
          git.call("init", "--quiet")
          git.call("-c", "http.extraHeader=", "fetch", "--no-tags", "--depth=1", "https://github.com/qtmleap/actions.git", revision)
          raise "Fetched revision mismatch" unless git.call("rev-parse", "FETCH_HEAD").strip == revision
          git.call("fsck", "--strict", "--no-reflogs")
          git.call("checkout", revision, "--", "runtime")
          FileUtils.mkdir_p(cache, mode: 0o700)
          FileUtils.mv(File.join(stage, "runtime"), cache)
        end
      end
      root = cache
    end
    root = File.realpath(root)
    raise "Runtime inside source" if root == app || root.start_with?(app + "/")
    files = lock.fetch("runtime_files")
    raise "Invalid digest map" unless files.is_a?(Hash) && files.key?("runtime/bootstrap.rb")
    files.each do |path, digest|
      raise "Unsafe runtime path" unless path.is_a?(String) && path.match?(%r{\Aruntime/[A-Za-z0-9_./-]+\z}) && path.split("/").none? { |part| %w[. ..].include?(part) }
      raise "Invalid runtime digest" unless digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/)
      full = File.join(root, path)
      raise "Runtime symlink" unless File.realpath(full) == full && File.file?(full)
      raise "Runtime content mismatch" unless Digest::SHA256.file(full).hexdigest == digest
    end
    require File.join(root, "runtime/bootstrap")
    SharedCI::Bootstrap.export!(root: root, app_root: app, revision: revision)
  end
end
