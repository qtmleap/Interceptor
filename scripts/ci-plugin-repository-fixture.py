#!/usr/bin/env python3
"""Run native UI tests with an owned HTTPS repository and simulator-only certificate trust."""
import argparse
import base64
import datetime
import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import socketserver
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'fixtures/plugin-repository'
PACKAGE_NAMES = ('request-summary.json', 'response-details.json', 'multi-file-hooks.json', 'approval-limits.json')
MARKER = 'Interceptor Plugin Repository Fixture'
# Pinned within the client's 90-day lifetime limit so visible payload hashes are
# reproducible. Renew deliberately with the visual baselines before expiry.
REPOSITORY_ISSUED_AT = '2026-10-01T00:00:00Z'
REPOSITORY_EXPIRES_AT = '2026-12-30T00:00:00Z'
DERIVED_BROWSER_PACKAGE = '/browser/target-hosts.json'
DERIVED_BROWSER_REPOSITORY = '/browser/repository.json'
DERIVED_OUTBOUND_PACKAGE = '/outbound/approval.json'
DERIVED_OUTBOUND_REPOSITORY = '/outbound/repository.json'
OUTBOUND_PACKAGE_ID = '3C0B5B0E-6D1F-4E57-9A52-7E1D4B8F2A61'
OUTBOUND_CATALOG_ID = 'A8F2C6D4-19B3-4C7E-8E05-5D2B9C41F7A3'
OUTBOUND_HOST = 'https://api.example.com'
# Deterministic binding order and declarations shown by the approval UI test.
OUTBOUND_BINDINGS = {
    'lookup': {'url': OUTBOUND_HOST + '/v1/profile', 'method': 'GET', 'headers': []},
    'post': {'url': OUTBOUND_HOST + '/v1/records', 'method': 'POST', 'headers': ['authorization', 'content-type']},
    'put': {'url': OUTBOUND_HOST + '/v1/records/latest', 'method': 'PUT', 'headers': ['content-type']},
}


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def load_packages():
    provenance = json.loads((FIXTURES / 'provenance.json').read_text())
    for name, expected in provenance['authoredInputs'].items():
        if digest((FIXTURES / name).read_bytes()) != expected:
            raise ValueError('Authored fixture changed without SDK regeneration: ' + name)
    for name, expected in provenance['packages'].items():
        raw = (FIXTURES / name).read_bytes()
        if digest(raw) != expected['sha256'] or len(raw) != expected['size']:
            raise ValueError('SDK-emitted package differs from provenance: ' + name)
    embedded = (ROOT / 'InterceptorTests/SDKFilesystemHookFixture.swift').read_text()
    encoded_package = re.search(r'base64Encoded: \s*"""(.*?)"""', embedded, re.S)
    if encoded_package is None or base64.b64decode(''.join(encoded_package.group(1).split()), validate=True) != (FIXTURES / 'sdk-live-multi-file-hooks.json').read_bytes():
        raise ValueError('Embedded live test package differs from actual SDK output')
    ui_sources = (ROOT / 'InterceptorUITests/PluginRepositorySources.swift').read_text()
    ui = json.loads((FIXTURES / 'multi-file-hooks.json').read_bytes())['sourceFiles']
    constants = {name: json.loads(value) for name, value in re.findall(r'static let (\w+File) = (".*")', ui_sources)}
    for name, body in re.findall(r'static let (\w+Source) = \[(.*?)\]\.joined\(separator: "\\n"\)', ui_sources, re.S):
        constants[name] = '\n'.join(json.loads(line.strip().rstrip(',')) for line in body.splitlines() if line.strip())
    if any(constants.get(leg + 'Source') != ui.get(constants.get(leg + 'File')) for leg in ('primary', 'secondary')):
        raise ValueError('UI source expectations differ from actual SDK output')
    limits_raw = (FIXTURES / 'approval-limits.json').read_bytes()
    limits = json.loads(limits_raw)['manifest']
    for label, expected in [('approvalPaths', [match['path']['value'] for match in limits['matches']]),
                            ('approvalReadFields', limits['read']['headers'] + limits['read']['queryKeys'])]:
        match = re.search(r'static let ' + label + r' = \[(.*?)\]', ui_sources, re.S)
        actual = [json.loads(line.strip().rstrip(',')) for line in match.group(1).splitlines() if line.strip()] if match else None
        if actual != expected:
            raise ValueError('Approval UI expectations differ from actual SDK output: ' + label)
    expected_revision = re.search(r'static let approvalRevision = "([a-f0-9]{64})"', ui_sources)
    if expected_revision is None or expected_revision.group(1) != digest(limits_raw):
        raise ValueError('Approval revision expectation differs from actual SDK output')
    packages = {}
    for name in PACKAGE_NAMES:
        path = FIXTURES / name
        if path.is_symlink() or not path.is_file():
            raise ValueError('Expected regular fixture: ' + name)
        raw = path.read_bytes()
        package = json.loads(raw)
        if name in provenance['packages']:
            expected = provenance['packages'][name]
            if digest(raw) != expected['sha256'] or len(raw) != expected['size']:
                raise ValueError('SDK-emitted package differs from provenance: ' + name)
        packages[name] = (raw, package['manifest'])
    return packages


def repository_files(token, device):
    packages = load_packages()
    entries = []
    files = {}
    for name, (raw, manifest) in packages.items():
        files['/' + name] = raw
        entries.append({key: manifest[key] for key in ('id', 'name', 'version')} | {
            'packagePath': name, 'sha256': digest(raw), 'size': len(raw)})
    payload = {'schemaVersion': 1, 'id': '57414817-0F72-40BA-A27C-535B784BEE00',
               'name': 'Local repository fixture', 'sequence': 1,
               'issuedAt': REPOSITORY_ISSUED_AT,
               'expiresAt': REPOSITORY_EXPIRES_AT, 'plugins': entries}
    files['/repository.json'] = encoded({'schemaVersion': 1, 'payload': base64.b64encode(encoded(payload)).decode()})
    # This separate catalog is explicitly synthetic: sourceFiles retain the SDK's
    # exact text, while identity and target metadata are authored for browser tests.
    # The original four-package catalog and SDK provenance remain unchanged.
    derived = json.loads(packages['multi-file-hooks.json'][0])
    derived['manifest'].update(id='E9472B70-2DB2-4F4C-A291-33F5FEF88519', name='Target hosts example',
                               author='Browser fixture author', category='Requests',
                               summary='Derived fixture for package and file target views.')
    target_rules = [rule for rule in derived['manifest']['matches']
                    if rule['path'] == {'kind': 'exact', 'value': '/synthetic'} and rule['methods'] == ['POST']]
    if len(target_rules) != 1:
        raise ValueError('Derived browser fixture requires one exact POST /synthetic rule')
    target_rules[0]['hosts'] = ['api.example.com']
    derived_raw = encoded(derived)
    files[DERIVED_BROWSER_PACKAGE] = derived_raw
    metadata = derived['manifest']
    derived_entry = {key: metadata[key] for key in ('id', 'name', 'version', 'author', 'summary', 'category')} | {
        'packagePath': 'target-hosts.json', 'sha256': digest(derived_raw), 'size': len(derived_raw)}
    derived_payload = payload | {'id': '532AEB4B-8744-44DA-86CB-DC46E3831F23',
                                 'name': 'Browser catalog fixture', 'plugins': [derived_entry]}
    files[DERIVED_BROWSER_REPOSITORY] = encoded({'schemaVersion': 1, 'payload': base64.b64encode(encoded(derived_payload)).decode()})
    # A second explicitly synthetic catalog, derived from multi-file-hooks.json, carries schema-2
    # outbound declarations. The original packages and the browser catalog stay byte-identical.
    outbound = json.loads(packages['multi-file-hooks.json'][0])
    outbound['manifest'].update(id=OUTBOUND_PACKAGE_ID, name='Outbound approval example',
                                author='Outbound fixture author', category='Requests',
                                summary='Derived fixture for outbound method and consent views.',
                                outbound=json.loads(json.dumps(OUTBOUND_BINDINGS)))
    outbound_raw = encoded(outbound)
    files[DERIVED_OUTBOUND_PACKAGE] = outbound_raw
    outbound_meta = outbound['manifest']
    outbound_entry = {key: outbound_meta[key] for key in ('id', 'name', 'version', 'author', 'summary', 'category')} | {
        'packagePath': 'approval.json', 'sha256': digest(outbound_raw), 'size': len(outbound_raw)}
    outbound_payload = payload | {'id': OUTBOUND_CATALOG_ID, 'name': 'Outbound catalog fixture', 'plugins': [outbound_entry]}
    files[DERIVED_OUTBOUND_REPOSITORY] = encoded({'schemaVersion': 1, 'payload': base64.b64encode(encoded(outbound_payload)).decode()})
    # Bind readiness only after every derived catalog and package has been added.
    package_digest = digest(encoded({path: digest(raw) for path, raw in files.items()}))
    files['/__interceptor_fixture'] = encoded({'fixture': MARKER, 'version': 1, 'runToken': token,
                                              'device': device, 'packageDigest': package_digest})
    return files, package_digest


def make_tls(work):
    tls = work / 'private-tls'
    previous = os.umask(0o077)
    try:
        tls.mkdir(mode=0o700)
        (tls / 'ca.cnf').write_text('''[req]
prompt=no
distinguished_name=dn
x509_extensions=ca
[dn]
CN=Interceptor run-owned UI fixture CA
[ca]
basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
''')
        (tls / 'server.cnf').write_text('''[req]
prompt=no
distinguished_name=dn
[dn]
CN=localhost
[server]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost,IP:127.0.0.1
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid
''')
        commands = [
            ['openssl', 'req', '-newkey', 'rsa:2048', '-nodes', '-x509', '-sha256', '-days', '2', '-config', str(tls / 'ca.cnf'), '-keyout', str(tls / 'ca.key'), '-out', str(tls / 'ca.pem')],
            ['openssl', 'req', '-new', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-config', str(tls / 'server.cnf'), '-keyout', str(tls / 'server.key'), '-out', str(tls / 'server.csr')],
            ['openssl', 'x509', '-req', '-sha256', '-days', '2', '-in', str(tls / 'server.csr'), '-CA', str(tls / 'ca.pem'), '-CAkey', str(tls / 'ca.key'), '-CAcreateserial', '-extfile', str(tls / 'server.cnf'), '-extensions', 'server', '-out', str(tls / 'server.pem')],
        ]
        for command in commands:
            result = subprocess.run(command, capture_output=True, text=True, timeout=20)
            if result.returncode:
                raise RuntimeError('Test certificate generation failed: ' + result.stderr[-500:])
    finally:
        os.umask(previous)
    return tls


class RequestDiagnostics:
    """Bounded, thread-safe request log: allowlisted path, status, size, timing, exception class only."""
    def __init__(self, allowed, limit=200):
        self.allowed = frozenset(allowed)
        self.limit = limit
        self.lock = threading.Lock()
        self.entries = []
        self.total = 0

    def record(self, path, status, size, elapsed, error=None):
        entry = {'path': path if path in self.allowed else '<unlisted>', 'status': status, 'bytes': size,
                 'elapsedSeconds': round(elapsed, 3), 'error': type(error).__name__ if error is not None else None}
        with self.lock:
            self.total += 1
            if len(self.entries) < self.limit:
                self.entries.append(entry)

    def snapshot(self):
        with self.lock:
            return {'limit': self.limit, 'total': self.total, 'dropped': self.total - len(self.entries),
                    'entries': [dict(entry) for entry in self.entries]}


def valid_port(value):
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 65535:
        raise ValueError('Fixture port must be an integer in 0..65535')
    return value


def port_argument(text):
    if not text.isascii() or not text.isdigit():
        raise argparse.ArgumentTypeError('port must be an integer in 0..65535')
    try:
        return valid_port(int(text))
    except ValueError as error:
        raise argparse.ArgumentTypeError(str(error))


class FixtureServer:
    def __init__(self, files, tls, port=0):
        port = valid_port(port)
        diagnostics = self.diagnostics = RequestDiagnostics(files)
        # Explicit bytes only: no filesystem traversal, directory listing, source tree or key serving.
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                started = time.monotonic()
                body = files.get(self.path)
                if body is None:
                    self.send_error(404)
                    diagnostics.record(self.path, 404, 0, time.monotonic() - started)
                    return
                self.send_response(200)
                self.send_header('Content-Type', 'application/json; charset=utf-8')
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Cache-Control', 'no-store')
                self.end_headers()
                self.wfile.write(body)
                diagnostics.record(self.path, 200, len(body), time.monotonic() - started)

            def log_message(self, *args):
                pass

        class Server(http.server.ThreadingHTTPServer):
            daemon_threads = True
            block_on_close = False

            def server_bind(self):
                # HTTPServer.server_bind reverse-resolves the address via socket.getfqdn; loopback needs no DNS.
                socketserver.TCPServer.server_bind(self)
                self.server_name, self.server_port = self.server_address[:2]

            def finish_request(self, request, client_address):
                started = time.monotonic()
                try:
                    super().finish_request(request, client_address)
                except Exception as error:
                    # TLS handshake/read failures surface here; keep the class name only.
                    diagnostics.record('<unlisted>', None, 0, time.monotonic() - started, error=error)
                    raise

            def handle_error(self, request, client_address):
                pass

            def get_request(self):
                connection, address = super().get_request()
                connection.settimeout(5)
                return connection, address

        self.server = Server(('127.0.0.1', port), Handler)
        try:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.minimum_version = ssl.TLSVersion.TLSv1_2
            context.load_cert_chain(tls / 'server.pem', tls / 'server.key')
            self.server.socket = context.wrap_socket(self.server.socket, server_side=True, do_handshake_on_connect=False)
        except BaseException:
            self.server.server_close()
            raise
        self.port = self.server.server_port
        self.base_url = 'https://localhost:' + str(self.port)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={'poll_interval': 0.1}, daemon=True)
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        if self.thread.is_alive():
            raise RuntimeError('Owned fixture server did not stop')


class ReadinessError(RuntimeError):
    """Readiness timeout carrying bounded, non-sensitive diagnostics."""
    def __init__(self, message, diagnostics):
        super().__init__(message)
        self.diagnostics = diagnostics


def describe_error(error):
    # Short owned-loopback error details; no environment values or key material.
    info = {'type': type(error).__name__}
    inner = error.reason if isinstance(error, urllib.error.URLError) else error
    info['reason'] = type(inner).__name__
    info['message'] = str(inner)[:200]
    for source, key in (('errno', 'errno'), ('verify_code', 'verifyCode'), ('verify_message', 'verifyMessage'), ('reason', 'sslReason')):
        value = getattr(inner, source, None)
        if isinstance(value, int) and not isinstance(value, bool):
            info[key] = value
        elif isinstance(value, str):
            info[key] = value[:200]
    return info


def tls_metadata():
    info = {'pythonVersion': sys.version.split()[0], 'opensslVersion': getattr(ssl, 'OPENSSL_VERSION', None)}
    try:
        info['opensslPath'] = shutil.which('openssl')
    except Exception:
        pass
    return info


def check_ready(server, tls, expected):
    context = ssl.create_default_context(cafile=str(tls / 'ca.pem'))
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=context))
    started = time.monotonic()
    deadline = started + 5
    attempts = 0
    recent = []
    last = None
    while True:
        attempts += 1
        try:
            with opener.open(server.base_url + '/__interceptor_fixture', timeout=1) as response:
                actual = response.read(4096)
            if actual != expected:
                raise RuntimeError('Fixture readiness identity mismatch')
            return context
        except InterruptedError:
            raise
        except (OSError, urllib.error.URLError) as error:
            if isinstance(error, urllib.error.URLError) and isinstance(error.reason, InterruptedError):
                raise error.reason
            last = describe_error(error)
            recent = (recent + [last['type'] + '/' + last['reason']])[-5:]
            now = time.monotonic()
            if now >= deadline:
                thread = getattr(server, 'thread', None)
                diagnostics = {'attempts': attempts, 'lastError': last, 'recentErrorTypes': recent,
                               'elapsedSeconds': round(now - started, 3),
                               'serverThreadAlive': thread.is_alive() if thread is not None else None,
                               'tls': tls_metadata()}
                raise ReadinessError('Owned HTTPS fixture did not become ready after %d attempts; last error %s/%s'
                                     % (attempts, last['type'], last['reason']), diagnostics) from error
            time.sleep(0.05)


def owned_device(device, device_set, before_path, host_path, command):
    uuid.UUID(device)
    device_set = device_set.resolve(strict=True)
    host = host_path.read_text().splitlines()
    if len(host) != 2 or host[0] != socket.gethostname() or Path(host[1]).resolve() != device_set:
        raise ValueError('Simulator ownership record must identify this host and exact device set')
    before = json.loads(before_path.read_text())['devices']
    if any(d['udid'].lower() == device.lower() for group in before.values() for d in group):
        raise ValueError('Fixture trust requires a run-created disposable simulator')
    selected = subprocess.run(['xcrun', 'simctl', '--set', str(device_set), 'list', 'devices', '--json'],
                              check=True, capture_output=True, text=True, timeout=20)
    devices = [d for runtime, group in json.loads(selected.stdout)['devices'].items() if '.iOS-' in runtime for d in group]
    match = next((d for d in devices if d['udid'].lower() == device.lower()), None)
    if match is None or match['state'] != 'Booted':
        raise ValueError('Selected run-owned simulator is not booted in the specified device set')
    destinations = [command[i + 1] for i, arg in enumerate(command[:-1]) if arg == '-destination']
    if (len(destinations) != 1 or ('id=' + device).lower() not in destinations[0].lower().split(',')
            or 'platform=ios simulator' not in destinations[0].lower().split(',')):
        raise ValueError('Fixture trust and the single xcodebuild -destination UUID must match')
    return device_set


def stop_child(child):
    if child is None or child.poll() is not None:
        return
    child.terminate()
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait(timeout=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-dir', type=Path)
    parser.add_argument('--device', default=os.environ.get('SIMULATOR_UUID'))
    parser.add_argument('--device-set', type=Path, default=os.environ.get('CI_SIMULATOR_DEVICE_SET'))
    parser.add_argument('--simulators-before', type=Path)
    parser.add_argument('--simulator-host', type=Path)
    parser.add_argument('--port', type=port_argument, default=0,
                        help='loopback HTTPS port; 0 (default) selects a free port, an occupied port fails')
    parser.add_argument('--verify-fixtures', action='store_true')
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    options = parser.parse_args()
    if options.verify_fixtures:
        load_packages()
        print('SDK-emitted fixture provenance verified')
        return 0
    command = options.command[1:] if options.command[:1] == ['--'] else options.command
    if not options.self_test:
        if not options.device or not options.device_set or not command:
            parser.error('run-owned device, device set and -- xcodebuild command are required')
        before = options.simulators_before or Path(os.environ['RUNNER_TEMP']) / 'simulators-before.json'
        host = options.simulator_host or Path(os.environ['RUNNER_TEMP']) / 'simulator-host.txt'
        device_set = owned_device(options.device, options.device_set, before, host, command)
    else:
        device_set = None
        options.device = 'self-test-no-simulator'
    work = options.work_dir
    if work is None:
        work = Path(tempfile.mkdtemp(prefix='plugin-repository-fixture-', dir=os.environ.get('RUNNER_TEMP')))
    else:
        work.mkdir(mode=0o700, parents=False, exist_ok=False)
    work = work.resolve()
    record = {'schemaVersion': 1, 'host': socket.gethostname(), 'device': options.device,
              'deviceSet': str(device_set) if device_set else None, 'simulatorTrustAdded': False,
              'serverStopped': False, 'privateKeysRemoved': False}
    token = str(uuid.uuid4())
    server = child = tls = None

    def interrupted(signum, _):
        raise InterruptedError(signum)

    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, interrupted)
    try:
        files, package_digest = repository_files(token, options.device)
        public = work / 'public'
        public.mkdir()
        for path, raw in files.items():
            destination = public / path[1:]
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(raw)
        tls = make_tls(work)
        server = FixtureServer(files, tls, options.port)
        record.update({'repositoryURL': server.base_url + '/repository.json', 'runToken': token,
                       'packageDigest': package_digest, 'publicFiles': {name: digest(raw) for name, raw in files.items()},
                       'derivedPackages': {DERIVED_BROWSER_PACKAGE: 'multi-file-hooks.json',
                                           DERIVED_OUTBOUND_PACKAGE: 'multi-file-hooks.json'}})
        context = check_ready(server, tls, files['/__interceptor_fixture'])
        if options.self_test:
            for path in (DERIVED_BROWSER_REPOSITORY, DERIVED_BROWSER_PACKAGE,
                         DERIVED_OUTBOUND_REPOSITORY, DERIVED_OUTBOUND_PACKAGE):
                with urllib.request.urlopen(server.base_url + path, context=context, timeout=2) as response:
                    if response.status != 200 or response.read() != files[path]:
                        raise RuntimeError('Derived browser fixture was not served exactly: ' + path)
            for path in ['/private-tls/ca.key', '/../private-tls/server.key', '/authored/plugins/ui-multifile/plugin.json']:
                try:
                    urllib.request.urlopen(server.base_url + path, context=context, timeout=2).close()
                    raise RuntimeError('Unexpected file served: ' + path)
                except urllib.error.HTTPError as error:
                    error.close()
                    if error.code != 404:
                        raise
            print('PASS own HTTPS CA/hostname/readiness, SDK provenance, explicit serving allowlist')
            record['exit'] = 0
            return 0
        subprocess.run(['xcrun', 'simctl', '--set', str(device_set), 'keychain', options.device, 'add-root-cert', str(tls / 'ca.pem')],
                       check=True, timeout=20)
        record['simulatorTrustAdded'] = True
        env = dict(os.environ)
        for name, value in {'URL': record['repositoryURL'], 'TOKEN': token, 'DEVICE': options.device, 'DIGEST': package_digest}.items():
            env['TEST_RUNNER_INTERCEPTOR_REPOSITORY_FIXTURE_' + name] = value
        # Remain inside the existing run-worker process group; it owns descendants and its anchor.
        child = subprocess.Popen(command, env=env)
        record['testProcessPID'] = child.pid
        record['exit'] = child.wait()
        return record['exit']
    except InterruptedError as error:
        record['interrupted'] = error.args[0]
        record['exit'] = 128 + error.args[0]
        return record['exit']
    except Exception as error:
        record['exit'] = 1
        record['failure'] = {'type': type(error).__name__, 'message': str(error)[:500]}
        if isinstance(error, ReadinessError):
            record['diagnostics'] = error.diagnostics
        raise
    finally:
        for signum in (signal.SIGINT, signal.SIGTERM):
            signal.signal(signum, signal.SIG_IGN)
        try:
            stop_child(child)
        finally:
            try:
                if server:
                    server.close()
                    record['serverStopped'] = True
            finally:
                record['requests'] = server.diagnostics.snapshot() if server else RequestDiagnostics(()).snapshot()
                # Keychain has no individual root-removal command. The existing owned-device
                # cleanup deletes this disposable simulator after the worker group has stopped.
                if (work / 'private-tls').exists():
                    shutil.rmtree(work / 'private-tls')
                record['privateKeysRemoved'] = not (work / 'private-tls').exists()
                (work / 'fixture-run.json').write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error))
