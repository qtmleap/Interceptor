# Runs every test file in its own process. Needs only Ruby: no fastlane, Apple tooling or network.
dir = __dir__
failed = Dir[File.join(dir, "*_test.rb")].sort.reject do |file|
  puts "== #{File.basename(file)}"
  system(RbConfig.ruby, file)
end
exit(failed.empty? ? 0 : 1)
