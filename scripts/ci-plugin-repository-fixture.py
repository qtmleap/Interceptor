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
PACKAGE_NAMES = ('request-summary.json', 'response-details.json', 'multi-file-hooks.json')
MARKER = 'Interceptor Plugin Repository Fixture'


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
    now = datetime.datetime.now(datetime.timezone.utc)
    iso = lambda date: date.isoformat(timespec='seconds').replace('+00:00', 'Z')
    payload = {'schemaVersion': 1, 'id': '57414817-0F72-40BA-A27C-535B784BEE00',
               'name': 'Local repository fixture', 'sequence': 1,
               'issuedAt': iso(now - datetime.timedelta(seconds=60)),
               'expiresAt': iso(now + datetime.timedelta(days=1)), 'plugins': entries}
    files['/repository.json'] = encoded({'schemaVersion': 1, 'payload': base64.b64encode(encoded(payload)).decode()})
    package_digest = digest(encoded(entries))
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


class FixtureServer:
    def __init__(self, files, tls):
        # Explicit bytes only: no filesystem traversal, directory listing, source tree or key serving.
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = files.get(self.path)
                if body is None:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header('Content-Type', 'application/json; charset=utf-8')
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Cache-Control', 'no-store')
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        class Server(http.server.ThreadingHTTPServer):
            daemon_threads = True
            block_on_close = False

            def get_request(self):
                connection, address = super().get_request()
                connection.settimeout(5)
                return connection, address

        self.server = Server(('127.0.0.1', 0), Handler)
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


def check_ready(server, tls, expected):
    context = ssl.create_default_context(cafile=str(tls / 'ca.pem'))
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=context))
    deadline = time.monotonic() + 5
    while True:
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
            if time.monotonic() >= deadline:
                raise RuntimeError('Owned HTTPS fixture did not become ready')
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
            (public / path[1:]).write_bytes(raw)
        tls = make_tls(work)
        server = FixtureServer(files, tls)
        record.update({'repositoryURL': server.base_url + '/repository.json', 'runToken': token,
                       'packageDigest': package_digest, 'publicFiles': {name: digest(raw) for name, raw in files.items()}})
        context = check_ready(server, tls, files['/__interceptor_fixture'])
        if options.self_test:
            for path in ['/private-tls/ca.key', '/../private-tls/server.key', '/authored/plugins/ui-multifile/plugin.json']:
                try:
                    urllib.request.urlopen(server.base_url + path, context=context, timeout=2)
                    raise RuntimeError('Unexpected file served: ' + path)
                except urllib.error.HTTPError as error:
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
