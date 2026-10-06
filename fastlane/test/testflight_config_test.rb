require "minitest/autorun"
require "tmpdir"

require_relative "../lib/testflight_config"

class TestFlightConfigTest < Minitest::Test
  def test_new_upload_uses_number_after_remote_build
    assert_equal 48, TestFlightConfig.next_build_number(local: "30", remote: 47)
  end

  def test_new_version_preserves_local_build_floor
    assert_equal 51, TestFlightConfig.next_build_number(local: "50", remote: 0)
  end

  def test_existing_release_31_is_not_reused
    assert_equal 32, TestFlightConfig.next_build_number(local: "30", remote: 0)
  end

  def test_invalid_remote_number_fails_instead_of_falling_back
    [nil, "", "31.2", "unavailable", -1].each do |remote|
      assert_raises(ArgumentError) { TestFlightConfig.next_build_number(local: 30, remote: remote) }
    end
  end

  def test_missing_credentials_report_names_without_values
    error = assert_raises(ArgumentError) do
      TestFlightConfig.validate_credentials!("APP_STORE_CONNECT_API_KEY_KEY" => "private-test-value")
    end
    assert_includes error.message, "MATCH_PASSWORD"
    refute_includes error.message, "private-test-value"
  end

  def test_both_signing_profiles_are_required_before_archiving
    assert_raises(ArgumentError) do
      TestFlightConfig.signing_targets("jp.qleap.intrcptr" => "match AppStore jp.qleap.intrcptr")
    end
  end

  def test_profiles_are_mapped_to_the_app_and_extension_targets
    result = TestFlightConfig.signing_targets(
      "jp.qleap.intrcptr" => "App Profile",
      "jp.qleap.intrcptr.packet-tunnel" => "VPN Profile"
    )
    assert_equal({"Interceptor" => "App Profile", "PacketTunnel" => "VPN Profile"}, result)
  end

  def test_upload_uses_private_home_and_restores_home_on_failure
    original = ENV["HOME"]
    Dir.mktmpdir do |dir|
      assert_raises(RuntimeError) do
        TestFlightConfig.with_upload_home(File.join(dir, "upload")) do
          assert_equal File.join(dir, "upload"), Dir.home
          assert_equal 0700, File.stat(Dir.home).mode & 0777
          raise "upload failed"
        end
      end
    end
    assert_equal original, ENV["HOME"]
  end
end
