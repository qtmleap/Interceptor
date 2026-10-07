# Minimal dependency-free test harness (no fastlane, Apple or network). Run with run_all.rb.
require "json"
require "tmpdir"
require "fileutils"
require "rbconfig"
require "stringio"

$failures = 0

def check(name)
  yield
  puts "ok   #{name}"
rescue StandardError, NotImplementedError => e
  $failures += 1
  puts "FAIL #{name}: #{e.class} #{e.message}"
  puts e.backtrace.first(3).map { |line| "       #{line}" } if ENV["TEST_TRACE"]
end

def assert(condition, message = "assertion failed")
  raise message unless condition
end

# Yields the raised error (or nil) of the block for the given classes.
def error_of(*classes)
  yield
  nil
rescue *classes => e
  e
end

def with_environment(values)
  previous = values.to_h { |key, _| [key, ENV[key]] }
  values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  yield
ensure
  previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
end

def finish
  if $failures.zero?
    puts "all passed"
  else
    puts "#{$failures} failed"
    exit 1
  end
end

MERGE = "a" * 40
BEFORE = "c" * 40
HEAD = "b" * 40
OTHER = "d" * 40
