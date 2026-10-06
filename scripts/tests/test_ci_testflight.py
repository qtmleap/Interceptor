import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "ci-testflight.sh"


class TestFlightCleanupTests(unittest.TestCase):
    def run_release(self, exit_code=0, missing=None):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            home = root / "home"
            home.mkdir()
            netrc = home / ".netrc"
            netrc.write_text("original host credentials\n")
            netrc.chmod(0o600)
            commands = root / "bin"
            commands.mkdir()
            calls = root / "security.jsonl"
            security = commands / "security"
            security.write_text("""#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
if '-p' in args:
    args[args.index('-p') + 1] = '<redacted>'
with open(os.environ['TEST_SECURITY_LOG'], 'a') as log:
    log.write(json.dumps(args) + '\\n')
if args == ['list-keychains', '-d', 'user']:
    print('    "/fixture/Login Keychain-db"')
    print('    "/fixture/second.keychain-db"')
""")
            security.chmod(0o755)
            bundle = commands / "bundle"
            bundle.write_text("""#!/usr/bin/env python3
import os, pathlib, subprocess, sys
assert sys.argv[1:] == ['exec', 'fastlane', 'ios', 'beta']
assert pathlib.Path(os.environ['HOME'], '.netrc').stat().st_mode & 0o777 == 0o600
assert pathlib.Path(os.environ['MATCH_KEYCHAIN_NAME']).parent.is_dir()
assert pathlib.Path(os.environ['RELEASE_DERIVED_DATA_PATH'], 'SourcePackages').is_symlink()
import tempfile
assert pathlib.Path(tempfile.gettempdir()).parent == pathlib.Path(os.environ['MATCH_KEYCHAIN_NAME']).parent
with tempfile.TemporaryDirectory(prefix='deliver-') as private:
    pathlib.Path(private, 'AuthKey_fixture.p8').write_text('temporary key fixture')
subprocess.run(['ruby', '-rtmpdir', '-e', 'Dir.mktmpdir("deliver-") { |d| abort "unsafe temporary directory" unless File.realpath(d).start_with?(File.realpath(ENV.fetch("TMPDIR")) + "/") }'], check=True)
upload_home = pathlib.Path(os.environ['RELEASE_UPLOAD_HOME'])
upload_home.mkdir()
(upload_home / 'temporary-private-key.p8').write_text('test key fixture')
sys.exit(int(os.environ['TEST_BUNDLE_EXIT']))
""")
            bundle.chmod(0o755)
            env = os.environ.copy()
            env.update({
                "HOME": str(home), "RUNNER_TEMP": str(root),
                "PATH": str(commands) + os.pathsep + env["PATH"],
                "TEST_SECURITY_LOG": str(calls), "TEST_BUNDLE_EXIT": str(exit_code),
                "APP_STORE_CONNECT_API_KEY_KEY_ID": "ABCDEFGHIJ",
                "APP_STORE_CONNECT_API_KEY_ISSUER_ID": "issuer-fixture",
                "APP_STORE_CONNECT_API_KEY_KEY": "private-api-key-fixture",
                "MATCH_PASSWORD": "password-fixture",
                "MATCH_GIT_BASIC_AUTHORIZATION": "git-fixture",
                "QUANTUMLEAP_READ_TOKEN": "quantum-token-fixture",
            })
            if missing:
                del env[missing]
            result = subprocess.run(["bash", str(SCRIPT)], env=env, text=True, capture_output=True)
            self.assertEqual(netrc.read_text(), "original host credentials\n")
            self.assertEqual(netrc.stat().st_mode & 0o777, 0o600)
            self.assertEqual(list(root.glob("interceptor-testflight.*")), [])
            for secret in ("private-api-key-fixture", "password-fixture", "quantum-token-fixture"):
                self.assertNotIn(secret, result.stdout + result.stderr)
            recorded = [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []
            return result, recorded

    def test_success_restores_keychains_and_removes_private_files(self):
        result, calls = self.run_release()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(["list-keychains", "-d", "user", "-s", "/fixture/Login Keychain-db", "/fixture/second.keychain-db"], calls)
        self.assertEqual(calls[-1][0], "delete-keychain")

    def test_failed_upload_preserves_failure_and_cleans_up(self):
        result, calls = self.run_release(exit_code=42)
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertEqual(calls[-1][0], "delete-keychain")

    def test_missing_credentials_stop_before_changing_keychains(self):
        result, calls = self.run_release(missing="MATCH_PASSWORD")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("MATCH_PASSWORD", result.stderr)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
