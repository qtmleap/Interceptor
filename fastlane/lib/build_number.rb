# Chooses the TestFlight build number: max(remote + 1, a CI-unique floor), never below the
# project's current number. Pure arithmetic with strict input validation; no source is touched.
module BuildNumber
  class Error < StandardError; end

  # CFBundleVersion is compared per marketing version, but a single global sequence is simpler and safe.
  LIMIT = 999_999_999

  module_function

  def integer!(value, name)
    text = value.to_s
    raise Error, "#{name} must be a nonnegative integer." unless text.match?(/\A[0-9]{1,9}\z/)

    Integer(text, 10)
  end

  # remote: highest number App Store Connect reports (0 when none).
  # local: number currently in the checked-out project (0 when unknown).
  # minimum: a number known to be used already (an upload from before CI existed).
  # ci_floor: GITHUB_RUN_NUMBER, which grows with every run of the serialized workflow.
  def next(remote:, local:, minimum:, ci_floor:)
    remote = integer!(remote, "The remote build number")
    local = integer!(local, "The project build number")
    minimum = integer!(minimum, "The minimum build number")
    ci_floor = integer!(ci_floor, "The CI run number")
    raise Error, "The CI run number must be positive." if ci_floor.zero?

    number = [remote + 1, local + 1, minimum + 1, ci_floor].max
    raise Error, "The build number exceeds the supported range." if number > LIMIT

    number
  end

  # The highest CURRENT_PROJECT_VERSION in a pbxproj text (0 when none is a plain integer).
  def project_floor(pbxproj_text)
    pbxproj_text.scan(/CURRENT_PROJECT_VERSION = "?(\d+)"?;/).flatten.map(&:to_i).max || 0
  end

  # Rewrites every plain CURRENT_PROJECT_VERSION; used only on the temporary build copy.
  def apply(pbxproj_text, number)
    count = 0
    updated = pbxproj_text.gsub(/(CURRENT_PROJECT_VERSION = )"?\d+"?;/) do
      count += 1
      "#{Regexp.last_match(1)}#{number};"
    end
    raise Error, "The project has no CURRENT_PROJECT_VERSION to set." if count.zero?

    [updated, count]
  end
end
