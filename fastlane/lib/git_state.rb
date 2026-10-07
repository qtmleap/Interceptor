# Read-only Git queries about the authorized checkout. Pure Ruby, no fastlane.
require "open3"

module GitState
  class Error < StandardError; end

  module_function

  def head_sha(repo_root, child_env: {})
    sha, status = Open3.capture2e(child_env, "git", "-C", repo_root, "rev-parse", "--verify", "HEAD^{commit}")
    raise Error, "Cannot read the HEAD commit of the release checkout." unless status.success?

    sha.strip
  rescue SystemCallError
    raise Error, "Cannot run git to read the HEAD commit."
  end

  # With -z, newlines in file names do not inflate the count; a rename or copy is one entry.
  # Returns nil when the state cannot be read so callers fail closed.
  def dirty_count(repo_root, child_env: {})
    output, status = Open3.capture2e(
      child_env, "git", "-C", repo_root, "status", "--porcelain", "-z", "--untracked-files=all"
    )
    return nil unless status.success?

    entries = output.split("\0")
    count = 0
    index = 0
    while index < entries.length
      index += entries[index][0, 2].match?(/[RC]/) ? 2 : 1
      count += 1
    end
    count
  rescue SystemCallError
    nil
  end
end
