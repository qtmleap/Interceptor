import base64
import datetime
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/ci-plugin-repository-fixture.py'
spec = importlib.util.spec_from_file_location('repository_fixture', SCRIPT)
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
DEVICE = 'AB6B45A2-2662-4C1B-9D50-B32BA0C8406B'


class PluginRepositoryFixtureTests(unittest.TestCase):
    def test_readiness_interrupt_propagates_without_retry(self):
        server = type('Server', (), {'base_url': 'https://localhost:1'})()
        for error in (InterruptedError(15), fixture.urllib.error.URLError(InterruptedError(15))):
            with self.subTest(error=type(error).__name__), \
                    patch.object(fixture.ssl, 'create_default_context', return_value=None), \
                    patch.object(fixture.urllib.request.OpenerDirector, 'open', side_effect=error), \
                    patch.object(fixture.time, 'monotonic', side_effect=[0, 6]), \
                    patch.object(fixture.time, 'sleep') as sleep:
                with self.assertRaises(InterruptedError) as raised:
                    fixture.check_ready(server, Path('/unused'), b'nonce')
                self.assertEqual(raised.exception.args, (15,))
                sleep.assert_not_called()

    def test_local_readiness_ignores_proxy_environment(self):
        with tempfile.TemporaryDirectory() as temporary:
            tls = fixture.make_tls(Path(temporary))
            server = fixture.FixtureServer({'/__interceptor_fixture': b'nonce'}, tls)
            try:
                proxy = 'http://127.0.0.1:1'
                environment = {key: proxy for key in ('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy')}
                environment.update(NO_PROXY='', no_proxy='')
                with patch.dict(os.environ, environment):
                    fixture.check_ready(server, tls, b'nonce')
            finally:
                server.close()

    def ownership(self, root, before):
        device_set = root / 'devices'
        device_set.mkdir()
        before_path = root / 'before.json'
        before_path.write_text(json.dumps({'devices': {'runtime': before}}))
        host = root / 'host.txt'
        host.write_text(socket.gethostname() + '\n' + str(device_set) + '\n')
        return device_set, before_path, host

    def test_repository_binds_nonce_device_and_exact_package_bytes(self):
        files, digest = fixture.repository_files('this-run', DEVICE)
        marker = json.loads(files['/__interceptor_fixture'])
        self.assertEqual(marker['runToken'], 'this-run')
        self.assertEqual(marker['device'], DEVICE)
        self.assertEqual(marker['packageDigest'], digest)
        envelope = json.loads(files['/repository.json'])
        index = json.loads(base64.b64decode(envelope['payload'], validate=True))
        self.assertEqual({e['name'] for e in index['plugins']}, {'Request summary', 'Response details', 'Multi-file hooks'})
        for entry in index['plugins']:
            raw = files['/' + entry['packagePath']]
            self.assertNotIn('/', entry['packagePath'])
            self.assertEqual(len(raw), entry['size'])
            self.assertEqual(fixture.digest(raw), entry['sha256'])
            for key in ('id', 'name', 'version'):
                self.assertEqual(json.loads(raw)['manifest'][key], entry[key])
        expires = datetime.datetime.fromisoformat(index['expiresAt'].replace('Z', '+00:00'))
        self.assertGreater(expires, datetime.datetime.now(datetime.timezone.utc))

    def test_preexisting_or_other_host_simulator_cannot_receive_trust(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            device_set, before, host = self.ownership(root, [{'udid': DEVICE}])
            with patch.object(fixture.subprocess, 'run') as run:
                with self.assertRaisesRegex(ValueError, 'run-created'):
                    fixture.owned_device(DEVICE, device_set, before, host, [])
                run.assert_not_called()
            host.write_text('another-host\n' + str(device_set) + '\n')
            with self.assertRaisesRegex(ValueError, 'this host'):
                fixture.owned_device(DEVICE, device_set, before, host, [])

    def test_exact_device_set_booted_state_and_single_destination_are_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            device_set, before, host = self.ownership(root, [])
            current = {'devices': {'com.apple.CoreSimulator.SimRuntime.iOS-26-5': [{'udid': DEVICE, 'state': 'Booted'}]}}
            response = subprocess.CompletedProcess([], 0, stdout=json.dumps(current))
            command = ['xcodebuild', 'test', '-destination', 'platform=iOS Simulator,id=' + DEVICE]
            with patch.object(fixture.subprocess, 'run', return_value=response) as run:
                self.assertEqual(fixture.owned_device(DEVICE, device_set, before, host, command), device_set.resolve())
                self.assertEqual(run.call_args.args[0][:4], ['xcrun', 'simctl', '--set', str(device_set.resolve())])
                with self.assertRaisesRegex(ValueError, 'destination UUID'):
                    fixture.owned_device(DEVICE, device_set, before, host, command + ['-destination', 'platform=iOS Simulator,id=' + DEVICE])
                with self.assertRaisesRegex(ValueError, 'destination UUID'):
                    fixture.owned_device(DEVICE, device_set, before, host, command[:-1] + ['platform=iOS Simulator,id=another-device'])
            current['devices']['com.apple.CoreSimulator.SimRuntime.iOS-26-5'][0]['state'] = 'Shutdown'
            with patch.object(fixture.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, stdout=json.dumps(current))):
                with self.assertRaisesRegex(ValueError, 'not booted'):
                    fixture.owned_device(DEVICE, device_set, before, host, command)

    def test_certificate_generation_failure_still_removes_owned_private_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary) / 'run'
            def broken_tls(path):
                private = path / 'private-tls'
                private.mkdir()
                (private / 'ca.key').write_text('test-only incomplete key')
                raise RuntimeError('expected certificate failure')
            with patch.object(sys, 'argv', [str(SCRIPT), '--self-test', '--work-dir', str(work)]), patch.object(fixture, 'make_tls', broken_tls), patch.object(fixture.signal, 'signal'):
                with self.assertRaisesRegex(RuntimeError, 'expected certificate failure'):
                    fixture.main()
            self.assertFalse((work / 'private-tls').exists())
            self.assertTrue(json.loads((work / 'fixture-run.json').read_text())['privateKeysRemoved'])

    def test_real_https_allowlist_and_owned_cleanup_without_simulator(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary) / 'run'
            completed = subprocess.run([sys.executable, str(SCRIPT), '--self-test', '--work-dir', str(work)],
                                       capture_output=True, text=True, timeout=20)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            record = json.loads((work / 'fixture-run.json').read_text())
            self.assertTrue(record['serverStopped'])
            self.assertTrue(record['privateKeysRemoved'])
            self.assertFalse(record['simulatorTrustAdded'])
            self.assertFalse(any('key' in name or 'private' in name for name in record['publicFiles']))


if __name__ == '__main__':
    unittest.main()
