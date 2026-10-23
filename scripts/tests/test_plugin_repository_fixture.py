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
import urllib.request
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
        issued = datetime.datetime.fromisoformat(index['issuedAt'].replace('Z', '+00:00'))
        self.assertLessEqual(issued, datetime.datetime.now(datetime.timezone.utc))
        self.assertLessEqual(expires - issued, datetime.timedelta(days=90))
        self.assertGreater(expires, datetime.datetime.now(datetime.timezone.utc))
        another_run, _ = fixture.repository_files('another-run', 'another-device')
        self.assertEqual(files['/repository.json'], another_run['/repository.json'],
                         'the visible payload hash must be stable across native runs')
        self.assertNotEqual(files['/__interceptor_fixture'], another_run['/__interceptor_fixture'],
                            'readiness remains bound to the individual run and device')

    def test_browser_variant_is_explicitly_derived_and_keeps_sdk_catalog_unchanged(self):
        files, _ = fixture.repository_files('this-run', DEVICE)
        envelope = json.loads(files['/browser/repository.json'])
        index = json.loads(base64.b64decode(envelope['payload'], validate=True))
        self.assertEqual(index['name'], 'Browser catalog fixture')
        self.assertEqual(len(index['plugins']), 1)
        entry = index['plugins'][0]
        self.assertEqual(entry['packagePath'], 'target-hosts.json')
        raw = files['/browser/' + entry['packagePath']]
        package = json.loads(raw)
        manifest = package['manifest']
        self.assertEqual(manifest['id'], 'E9472B70-2DB2-4F4C-A291-33F5FEF88519')
        self.assertEqual(manifest['name'], 'Target hosts example')
        self.assertEqual(manifest['category'], 'Requests')
        self.assertEqual(manifest['author'], 'Browser fixture author')
        self.assertEqual(manifest['summary'], 'Derived fixture for package and file target views.')
        for key in ('id', 'name', 'version', 'author', 'summary', 'category'):
            self.assertEqual(entry[key], manifest[key])
        self.assertEqual(entry['sha256'], fixture.digest(raw))
        self.assertEqual(entry['size'], len(raw))
        self.assertEqual({host for rule in manifest['matches'] for host in rule['hosts']},
                         {'example.com', 'api.example.com'})
        sdk = json.loads(files['/multi-file-hooks.json'])
        self.assertNotEqual(manifest['id'], sdk['manifest']['id'])
        self.assertEqual(package['sourceFiles'], sdk['sourceFiles'],
                         'derived target metadata must retain the actual SDK-emitted source bytes')
        self.assertEqual(files['/multi-file-hooks.json'], (fixture.FIXTURES / 'multi-file-hooks.json').read_bytes())
        for rule in manifest['matches']:
            self.assertTrue({file for phases in rule['hooks'].values() for file in phases.values()}
                            <= set(package['sourceFiles']))

    BASE_HASHES = {
        '/request-summary.json': 'f7985fe4eb7a5d60bcc69fc682b0f853e0c22a7a2a52bab84b1e1bccebe2ed12',
        '/response-details.json': '841f9582b395c81964f1a875980f102aa3c2942079f8e42c32571725e8761210',
        '/multi-file-hooks.json': '6f007a8e930949b7e0094b59b17cbfb82128eaf196156edd9901495f543440fa',
        '/approval-limits.json': '80b1908a2ddeef087e5b419bc07dae8ac2c61279f10eed40b934e814ae9b50af',
        '/repository.json': '8b73cee200453d88937e75252721418d4ce63784a2d2222f61f6564764cb8eae',
        '/browser/target-hosts.json': '30fd5c5184f04d685115d3fee7c4c0c330c77fb09ba4eb964d9bb6c859bb59ae',
        '/browser/repository.json': '9e262cd56b3ff8e41afd8675d70e156e872fe1c2b471af41c801d4cfbd8a67f4',
    }

    def test_original_served_bytes_match_hardcoded_pre_outbound_hashes(self):
        files, _ = fixture.repository_files('this-run', DEVICE)
        for path, expected in self.BASE_HASHES.items():
            self.assertEqual(fixture.digest(files[path]), expected, path)

    def test_outbound_variant_is_explicitly_derived_with_three_deterministic_bindings(self):
        files, _ = fixture.repository_files('this-run', DEVICE)
        index = json.loads(base64.b64decode(json.loads(files['/outbound/repository.json'])['payload'], validate=True))
        self.assertEqual(index['name'], 'Outbound catalog fixture')
        self.assertEqual(len(index['plugins']), 1)
        entry = index['plugins'][0]
        self.assertEqual(entry['packagePath'], 'approval.json')
        raw = files['/outbound/' + entry['packagePath']]
        package = json.loads(raw)
        manifest = package['manifest']
        self.assertEqual(manifest['name'], 'Outbound approval example')
        self.assertEqual(entry['sha256'], fixture.digest(raw))
        self.assertEqual(entry['size'], len(raw))
        for key in ('id', 'name', 'version', 'author', 'summary', 'category'):
            self.assertEqual(entry[key], manifest[key])
        self.assertEqual(manifest['outbound'], {
            'lookup': {'url': 'https://api.example.com/v1/profile', 'method': 'GET', 'headers': []},
            'post': {'url': 'https://api.example.com/v1/records', 'method': 'POST', 'headers': ['authorization', 'content-type']},
            'put': {'url': 'https://api.example.com/v1/records/latest', 'method': 'PUT', 'headers': ['content-type']},
        })
        sdk = json.loads(files['/multi-file-hooks.json'])
        self.assertNotIn(manifest['id'], {sdk['manifest']['id'], 'E9472B70-2DB2-4F4C-A291-33F5FEF88519'})
        self.assertEqual(package['sourceFiles'], sdk['sourceFiles'])
        self.assertNotIn('outbound', sdk['manifest'])
        self.assertNotEqual(index['id'], '57414817-0F72-40BA-A27C-535B784BEE00')
        self.assertNotEqual(index['id'], '532AEB4B-8744-44DA-86CB-DC46E3831F23')

    def test_native_outbound_expectations_match_served_package(self):
        import re
        files, _ = fixture.repository_files('this-run', DEVICE)
        native = (ROOT / 'InterceptorUITests/AutomationUITests.swift').read_text()
        revision = re.search(r'outboundRevision = "([a-f0-9]{64})"', native)
        identifier = re.search(r'outboundID = "([0-9A-F-]{36})"', native)
        self.assertIsNotNone(revision)
        self.assertEqual(revision.group(1), fixture.digest(files['/outbound/approval.json']))
        self.assertEqual(identifier.group(1), json.loads(files['/outbound/approval.json'])['manifest']['id'])
        for binding in json.loads(files['/outbound/approval.json'])['manifest']['outbound'].values():
            self.assertIn('"%s %s"' % (binding['method'], binding['url']), native)

    def test_readiness_digest_binds_every_allowlisted_catalog_and_package(self):
        files, bound_digest = fixture.repository_files('this-run', DEVICE)
        payload_files = {path: fixture.digest(raw) for path, raw in files.items() if path != '/__interceptor_fixture'}
        self.assertEqual(bound_digest, fixture.digest(fixture.encoded(payload_files)))
        changed = dict(payload_files)
        changed['/browser/target-hosts.json'] = '0' * 64
        self.assertNotEqual(bound_digest, fixture.digest(fixture.encoded(changed)))
        self.assertIn('/outbound/repository.json', payload_files)
        self.assertIn('/outbound/approval.json', payload_files)
        changed = dict(payload_files)
        changed['/outbound/approval.json'] = '0' * 64
        self.assertNotEqual(bound_digest, fixture.digest(fixture.encoded(changed)))

    def test_browser_derivation_targets_the_exact_file_independent_of_rule_order(self):
        packages = fixture.load_packages()
        package = json.loads(packages['multi-file-hooks.json'][0])
        package['manifest']['matches'].reverse()
        packages['multi-file-hooks.json'] = (fixture.encoded(package), package['manifest'])
        with patch.object(fixture, 'load_packages', return_value=packages):
            files, _ = fixture.repository_files('this-run', DEVICE)
        derived = json.loads(files['/browser/target-hosts.json'])
        for rule in derived['manifest']['matches']:
            if rule['path']['value'] == '/synthetic':
                self.assertEqual(rule['hosts'], ['api.example.com'])
                self.assertEqual(rule['methods'], ['POST'])
                self.assertEqual({file for phases in rule['hooks'].values() for file in phases.values()},
                                 {'hooks/example.com/synthetic/POST.js'})
            else:
                self.assertEqual(rule['hosts'], ['example.com'])

    def test_browser_variant_is_served_over_https_and_written_under_owned_public_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary) / 'run'
            with patch.object(sys, 'argv', [str(SCRIPT), '--self-test', '--work-dir', str(work)]), patch.object(fixture.signal, 'signal'):
                self.assertEqual(fixture.main(), 0)
            record = json.loads((work / 'fixture-run.json').read_text())
            self.assertIn('/browser/repository.json', record['publicFiles'])
            self.assertIn('/browser/target-hosts.json', record['publicFiles'])
            self.assertEqual(record['derivedPackages'], {'/browser/target-hosts.json': 'multi-file-hooks.json',
                                                         '/outbound/approval.json': 'multi-file-hooks.json'})
            self.assertIn('/outbound/repository.json', record['publicFiles'])
            self.assertIn('/outbound/approval.json', record['publicFiles'])
            self.assertTrue((work / 'public/browser/repository.json').is_file())
            served = {(entry['path'], entry['status']) for entry in record['requests']['entries']}
            self.assertIn(('/browser/repository.json', 200), served)
            self.assertIn(('/browser/target-hosts.json', 200), served)
            self.assertIn(('/outbound/repository.json', 200), served)
            self.assertIn(('/outbound/approval.json', 200), served)
            self.assertTrue(record['serverStopped'])
            self.assertTrue(record['privateKeysRemoved'])

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

    def reserved_free_port(self):
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            return probe.getsockname()[1]

    def test_explicit_port_serves_real_https_response(self):
        port = self.reserved_free_port()
        with tempfile.TemporaryDirectory() as temporary:
            tls = fixture.make_tls(Path(temporary))
            server = fixture.FixtureServer({'/__interceptor_fixture': b'nonce'}, tls, port=port)
            try:
                self.assertEqual(server.port, port)
                self.assertEqual(server.base_url, 'https://localhost:' + str(port))
                context = fixture.check_ready(server, tls, b'nonce')
                with urllib.request.urlopen(server.base_url + '/__interceptor_fixture', context=context, timeout=5) as response:
                    self.assertEqual(response.status, 200)
                    self.assertEqual(response.read(), b'nonce')
            finally:
                server.close()

    def test_occupied_port_fails_and_preserves_original_listener(self):
        with tempfile.TemporaryDirectory() as temporary, socket.socket() as occupied:
            tls = fixture.make_tls(Path(temporary))
            occupied.bind(('127.0.0.1', 0))
            occupied.listen(1)
            port = occupied.getsockname()[1]
            with self.assertRaises(OSError):
                fixture.FixtureServer({'/x': b'x'}, tls, port=port)
            self.assertEqual(occupied.getsockname(), ('127.0.0.1', port))
            occupied.settimeout(2)
            with socket.create_connection(('127.0.0.1', port), timeout=2):
                occupied.accept()[0].close()

    def test_constructor_rejects_invalid_ports(self):
        for bad in (-1, 65536, True, False, 1.0, '80', None):
            with self.subTest(port=bad), self.assertRaises(ValueError):
                fixture.FixtureServer({}, Path('unused'), port=bad)

    def test_cli_rejects_invalid_ports(self):
        for bad in ('-1', '65536', 'abc', '', '1.5', ' 80', '٣'):
            with self.subTest(port=bad):
                completed = subprocess.run([sys.executable, str(SCRIPT), '--self-test', '--port', bad],
                                           capture_output=True, text=True, timeout=20)
                self.assertEqual(completed.returncode, 2, completed.stderr)
                self.assertIn('port', completed.stderr)

    def test_cli_explicit_port_is_used_in_repository_url(self):
        port = self.reserved_free_port()
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary) / 'run'
            completed = subprocess.run([sys.executable, str(SCRIPT), '--self-test', '--port', str(port), '--work-dir', str(work)],
                                       capture_output=True, text=True, timeout=20)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            record = json.loads((work / 'fixture-run.json').read_text())
            self.assertEqual(record['repositoryURL'], 'https://localhost:%d/repository.json' % port)
            self.assertTrue(record['serverStopped'])

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
