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

    def test_persistent_readiness_failure_keeps_cause_and_bounded_diagnostics(self):
        server = type('Server', (), {'base_url': 'https://localhost:1'})()
        verify = fixture.ssl.SSLCertVerificationError(1, 'certificate verify failed: hostname mismatch')
        verify.verify_code, verify.verify_message = 5, 'hostname mismatch'
        errors = [fixture.urllib.error.URLError(ConnectionRefusedError(61, 'refused'))] * 6 + [fixture.urllib.error.URLError(verify)]
        clock = iter([0] * 7 + [6])
        with patch.object(fixture.ssl, 'create_default_context', return_value=None), \
                patch.object(fixture.urllib.request.OpenerDirector, 'open', side_effect=errors), \
                patch.object(fixture.time, 'monotonic', side_effect=lambda: next(clock)), \
                patch.object(fixture.time, 'sleep'):
            with self.assertRaises(RuntimeError) as raised:
                fixture.check_ready(server, Path('/unused'), b'nonce')
        error = raised.exception
        self.assertIsInstance(error.__cause__, fixture.urllib.error.URLError)
        self.assertIs(error.__cause__.reason, verify)
        info = error.diagnostics
        self.assertEqual(info['attempts'], 7)
        self.assertEqual(info['lastError']['type'], 'URLError')
        self.assertEqual(info['lastError']['reason'], 'SSLCertVerificationError')
        self.assertEqual(info['lastError']['verifyCode'], 5)
        self.assertEqual(info['lastError']['verifyMessage'], 'hostname mismatch')
        self.assertEqual(len(info['recentErrorTypes']), 5)
        self.assertEqual(info['recentErrorTypes'][-2], 'URLError/ConnectionRefusedError')
        self.assertEqual(info['recentErrorTypes'][-1], 'URLError/SSLCertVerificationError')
        self.assertEqual(info['elapsedSeconds'], 6)
        self.assertIn('7 attempts', str(error))
        self.assertIn('SSLCertVerificationError', str(error))

    def test_string_readiness_reason_is_retained_and_bounded(self):
        info = fixture.describe_error(fixture.urllib.error.URLError('x' * 500))
        self.assertEqual(info['reason'], 'str')
        self.assertEqual(info['message'], 'x' * 200)

    def test_main_records_failure_exit_and_diagnostics_and_still_cleans_up(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary) / 'run'
            failure = fixture.ReadinessError('not ready', {'attempts': 3})
            with patch.object(sys, 'argv', [str(SCRIPT), '--self-test', '--work-dir', str(work)]), \
                    patch.object(fixture, 'check_ready', side_effect=failure), patch.object(fixture.signal, 'signal'):
                with self.assertRaisesRegex(RuntimeError, 'not ready'):
                    fixture.main()
            record = json.loads((work / 'fixture-run.json').read_text())
            self.assertEqual(record['exit'], 1)
            self.assertEqual(record['diagnostics'], {'attempts': 3})
            self.assertEqual(record['failure'], {'type': 'ReadinessError', 'message': 'not ready'})
            self.assertTrue(record['serverStopped'])
            self.assertTrue(record['privateKeysRemoved'])
            self.assertFalse((work / 'private-tls').exists())

    def test_recorder_is_bounded_and_keeps_only_allowlisted_paths(self):
        recorder = fixture.RequestDiagnostics({'/repository.json'}, limit=200)
        for index in range(250):
            recorder.record('/repository.json?token=secret-%d' % index if index % 2 else '/repository.json', 200, 10, 0.01)
        snapshot = recorder.snapshot()
        self.assertEqual(len(snapshot['entries']), 200)
        self.assertEqual(snapshot['limit'], 200)
        self.assertEqual(snapshot['dropped'], 50)
        self.assertEqual(snapshot['total'], 250)
        self.assertEqual({entry['path'] for entry in snapshot['entries']}, {'/repository.json', '<unlisted>'})
        self.assertNotIn('secret', json.dumps(snapshot))
        self.assertEqual(fixture.RequestDiagnostics(set()).snapshot()['limit'], 200)

    def test_recorder_is_thread_safe_and_snapshot_is_detached(self):
        recorder = fixture.RequestDiagnostics({'/a'}, limit=200)
        def work():
            for _ in range(100):
                recorder.record('/a', 200, 1, 0.0)
        threads = [fixture.threading.Thread(target=work) for _ in range(8)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        snapshot = recorder.snapshot()
        self.assertEqual(snapshot['total'], 800)
        self.assertEqual(len(snapshot['entries']), 200)
        self.assertEqual(snapshot['dropped'], 600)
        snapshot['entries'].clear()
        self.assertEqual(len(recorder.snapshot()['entries']), 200)

    def test_recorder_stores_only_safe_exception_type(self):
        recorder = fixture.RequestDiagnostics({'/a'})
        recorder.record('/a', None, 3, 0.5, error=ValueError('Authorization: Bearer secret-token'))
        entry = recorder.snapshot()['entries'][0]
        self.assertEqual(entry['error'], 'ValueError')
        self.assertEqual(entry['status'], None)
        self.assertEqual(entry['bytes'], 3)
        self.assertEqual(entry['elapsedSeconds'], 0.5)
        self.assertNotIn('secret', json.dumps(entry))
        self.assertEqual(set(entry), {'path', 'status', 'bytes', 'elapsedSeconds', 'error'})

    def test_server_records_completed_requests_without_query_or_headers(self):
        with tempfile.TemporaryDirectory() as temporary:
            tls = fixture.make_tls(Path(temporary))
            body = b'{"ok":true}'
            server = fixture.FixtureServer({'/package.json': body}, tls)
            try:
                context = fixture.ssl.create_default_context(cafile=str(tls / 'ca.pem'))
                for expected_count, path in enumerate(('/package.json', '/package.json?runToken=secret-query', '/missing'), 1):
                    request = fixture.urllib.request.Request(server.base_url + path, headers={'Authorization': 'Bearer secret-header'})
                    try:
                        with fixture.urllib.request.urlopen(request, context=context, timeout=5) as response:
                            response.read()
                    except fixture.urllib.error.HTTPError as error:
                        with error:
                            error.read()
                    # Response delivery can precede bookkeeping. Complete each handler before
                    # starting the next request so the ordered assertion also stays deterministic.
                    deadline = fixture.time.monotonic() + 5
                    entries = server.diagnostics.snapshot()['entries']
                    while len(entries) < expected_count and fixture.time.monotonic() < deadline:
                        fixture.time.sleep(0.02)
                        entries = server.diagnostics.snapshot()['entries']
                    self.assertEqual(len(entries), expected_count, 'request handler diagnostics did not complete')
            finally:
                server.close()
            self.assertEqual([(e['path'], e['status']) for e in entries],
                             [('/package.json', 200), ('<unlisted>', 404), ('<unlisted>', 404)])
            self.assertEqual(entries[0]['bytes'], len(body))
            self.assertGreaterEqual(entries[0]['elapsedSeconds'], 0)
            self.assertNotIn('secret', json.dumps(entries))

    def test_loopback_fixture_does_not_depend_on_reverse_dns(self):
        def forbidden(*args, **kwargs):
            raise AssertionError('Fixture must not perform reverse DNS')
        with tempfile.TemporaryDirectory() as temporary:
            tls = fixture.make_tls(Path(temporary))
            expected = b'{"ok":true}'
            with patch.object(socket, 'getfqdn', forbidden), patch.object(socket, 'gethostbyaddr', forbidden):
                server = fixture.FixtureServer({'/__interceptor_fixture': expected}, tls)
                try:
                    self.assertEqual(server.server.server_name, '127.0.0.1')
                    self.assertEqual(server.server.server_port, server.port)
                    context = fixture.check_ready(server, tls, expected)
                    self.assertIsNotNone(context)
                finally:
                    server.close()

    def test_server_records_tls_handshake_failure_type_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            tls = fixture.make_tls(Path(temporary))
            server = fixture.FixtureServer({'/package.json': b'{}'}, tls)
            try:
                with socket.create_connection(('127.0.0.1', server.port), timeout=5) as raw:
                    raw.sendall(b'GET /package.json?secret=plain HTTP/1.1\r\nAuthorization: secret-plain\r\n\r\n')
                    raw.settimeout(5)
                    try:
                        raw.recv(1)
                    except OSError:
                        pass
                deadline = fixture.time.monotonic() + 5
                while not server.diagnostics.snapshot()['entries'] and fixture.time.monotonic() < deadline:
                    fixture.time.sleep(0.02)
                entries = server.diagnostics.snapshot()['entries']
            finally:
                server.close()
            self.assertEqual(len(entries), 1)
            self.assertEqual(entries[0]['path'], '<unlisted>')
            self.assertIsNone(entries[0]['status'])
            self.assertIn('SSL', entries[0]['error'])
            self.assertNotIn('secret', json.dumps(entries))

    def test_main_persists_request_diagnostics_on_success_and_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary) / 'success'
            with patch.object(sys, 'argv', [str(SCRIPT), '--self-test', '--work-dir', str(work)]), patch.object(fixture.signal, 'signal'):
                self.assertEqual(fixture.main(), 0)
            requests = json.loads((work / 'fixture-run.json').read_text())['requests']
            self.assertEqual(requests['limit'], 200)
            self.assertIn(('/__interceptor_fixture', 200), [(e['path'], e['status']) for e in requests['entries']])
            self.assertEqual([e['status'] for e in requests['entries'] if e['path'] == '<unlisted>'], [404, 404, 404])
            failed = Path(temporary) / 'failure'
            with patch.object(sys, 'argv', [str(SCRIPT), '--self-test', '--work-dir', str(failed)]), \
                    patch.object(fixture, 'check_ready', side_effect=fixture.ReadinessError('not ready', {})), patch.object(fixture.signal, 'signal'):
                with self.assertRaises(RuntimeError):
                    fixture.main()
            record = json.loads((failed / 'fixture-run.json').read_text())
            self.assertEqual(record['requests']['entries'], [])
            self.assertTrue(record['serverStopped'])
            self.assertTrue(record['privateKeysRemoved'])

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
        self.assertEqual({e['name'] for e in index['plugins']}, {'Request summary', 'Response details', 'Multi-file hooks', 'Approval limits'})
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
