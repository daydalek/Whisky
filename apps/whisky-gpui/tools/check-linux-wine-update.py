#!/usr/bin/env python3
"""Exercise Wine download/update jobs using real helpers, HTTP and isolated XDG data."""
import argparse
import contextlib
import hashlib
import http.server
import io
import json
import os
from pathlib import Path
import runpy
import tarfile
import tempfile
import threading
import time

REPO = 'daydalek/ge-proton-macos-wine-poc'
ARCHIVE = 'wine-linux-amd64.tar.gz'


def archive_bytes(attack=False):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode='w:gz') as archive:
        for name in ('bin/wine', 'bin/wineserver', 'run'):
            value = bytearray(64)
            value[:6], value[18:20] = b'\x7fELF\x02\x01', b'\x3e\x00'
            if name == 'run':
                value = b'#!/bin/sh\nexit 0\n'
            entry = tarfile.TarInfo('wine-linux-amd64/' + name)
            entry.size, entry.mode = len(value), 0o755
            archive.addfile(entry, io.BytesIO(value))
        if attack:
            entry = tarfile.TarInfo('wine-linux-amd64/lib/escape')
            entry.type, entry.linkname = tarfile.SYMTYPE, '/tmp/whisky-escape'
            archive.addfile(entry)
    return output.getvalue()


class FixtureServer:
    def __init__(self):
        self.responses = {}
        self.requests = []
        self.delay_archive = False
        self.archive_started = threading.Event()
        owner = self
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                owner.requests.append(self.path)
                value = owner.responses.get(self.path)
                if value is None:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header('Content-Length', str(len(value)))
                self.end_headers()
                if self.path.endswith('/' + ARCHIVE):
                    owner.archive_started.set()
                    while owner.delay_archive:
                        time.sleep(0.02)
                with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                    self.wfile.write(value)
            def log_message(self, *args):
                pass
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.daemon_threads = True
        self.origin = 'http://127.0.0.1:' + str(self.server.server_port)
        self.endpoint = self.origin + '/repos/' + REPO + '/releases'
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def publish(self, version, corrupt=False, attack=False, truncate=False):
        tag = 'v' + version + '-linux-amd64'
        prefix = '/' + REPO + '/releases/download/' + tag + '/'
        data = archive_bytes(attack)
        manifest = json.dumps(dict(runtime_asset=ARCHIVE, prefix_architecture='win64', target='Ubuntu 24.04 x86_64',
            validation_mode='compile-only', entrypoints=dict(wine='run', loader='bin/wine', wineserver='bin/wineserver'))).encode()
        sums = (hashlib.sha256(data).hexdigest() + '  ' + ARCHIVE + '\n'
                + hashlib.sha256(manifest).hexdigest() + '  linux-release-manifest.json\n').encode()
        assets = [(ARCHIVE, data), ('linux-release-manifest.json', manifest), ('SHA256SUMS-linux-amd64', sums)]
        release = dict(tag_name=tag, draft=False, prerelease=True, assets=[dict(name=name, state='uploaded', size=len(value),
            browser_download_url=self.origin + prefix + name, digest='sha256:' + hashlib.sha256(value).hexdigest())
            for name, value in assets])
        self.responses = {prefix + name: value for name, value in assets}
        if corrupt:
            self.responses[prefix + ARCHIVE] = b'x' * len(data)
        if truncate:
            self.responses[prefix + ARCHIVE] = data[:-10]
        # A newer macOS-only release stays outside the Linux channel.
        self.responses['/repos/' + REPO + '/releases'] = json.dumps([
            dict(tag_name='v99.0.0', draft=False, assets=[]), release]).encode()

    def close(self):
        self.delay_archive = False
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--real-release', action='store_true', help='Also download and validate the published GitHub payload')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    fixture = Path(tempfile.mkdtemp(prefix='fixture-', dir=output))
    bridge_type = runpy.run_path(str(Path(__file__).with_name('check-diagnostics.py')))['Bridge']
    server = FixtureServer()
    env = {key: value for key, value in os.environ.items()
           if key not in ('WHISKY_BRIDGE_NO_WINE', 'WHISKY_WINE_RUNTIME', 'WHISKY_WINE_FALLBACK_RUNTIME',
                          'WHISKY_LINUX_WINE_RELEASES_URL')}
    env.update(WHISKY_REGISTRY=str(fixture / 'BottleVM.plist'), XDG_CONFIG_HOME=str(fixture / 'config'),
               XDG_DATA_HOME=str(fixture / "Data 包 %f $HOME 'literal'"), XDG_STATE_HOME=str(fixture / 'state'),
               WHISKY_LINUX_WINE_RELEASES_URL=server.endpoint)
    report = dict(passed=False, steps=[], fixture=str(fixture))
    log = (output / 'helper.log').open('w')
    bridge = None

    def start(environment=env):
        return bridge_type(args.helper.resolve(), environment, log)

    def result(method, params=None, expected=None, timeout=120):
        reply = bridge.call(method, params or {})
        assert 'error' not in reply, reply
        job = reply['result']['jobID']
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            state = bridge.call('jobs.get', dict(jobID=job))['result']
            if state['status'] in ('completed', 'failed', 'cancelled'):
                if expected:
                    assert state.get('error', {}).get('code') == expected, state
                else:
                    assert state['status'] == 'completed', state
                return state
            time.sleep(0.02)
        raise AssertionError('Wine setup job timed out: ' + method)

    try:
        server.publish('0.1.6')
        bridge = start()
        methods = bridge.call('bridge.describe', {})['result']['methods']
        assert {'setup.status', 'setup.install', 'setup.checkUpdate'}.issubset(methods)
        assert 'runtime.launch' not in methods
        assert bridge.call('setup.status', {})['result']['installed'] is False
        assert result('setup.checkUpdate')['result']['remoteVersion'] == '0.1.6'
        assert result('setup.install')['result']['version'] == '0.1.6'
        original = Path(bridge.call('setup.status', {})['result']['path'])
        assert original.is_dir()
        bridge.close()
        bridge = start()
        assert 'runtime.launch' in bridge.call('bridge.describe', {})['result']['methods']
        assert bridge.call('setup.status', {})['result']['version'] == '0.1.6'
        report['steps'].append('real-http-prerelease-discovery-install-and-runtime-activation-after-helper-restart')
        server.publish('0.1.7')
        assert result('setup.checkUpdate')['result']['updateAvailable'] is True
        assert result('setup.install')['result']['version'] == '0.1.7'
        updated = bridge.call('setup.status', {})['result']['path']
        assert updated != str(original) and original.is_dir()
        report['steps'].append('numeric-update-atomic-activation-and-previous-generation-preservation')
        for corrupt, attack, truncate, expected in ((True, False, False, 'checksum_mismatch'),
                (False, True, False, 'invalid_archive'), (False, False, True, 'download_failed')):
            server.publish('0.1.8', corrupt=corrupt, attack=attack, truncate=truncate)
            result('setup.install', expected=expected)
            assert bridge.call('setup.status', {})['result']['path'] == updated
        report['steps'].append('checksum-external-symlink-and-truncated-download-failures-preserve-current-runtime')
        server.publish('0.1.6')
        assert result('setup.install', dict(force=True))['result']['version'] == '0.1.7'
        report['steps'].append('forced-install-keeps-a-newer-local-version')
        bridge.call('preferences.set', dict(key='checkWhiskyWineUpdates', value=False))
        before = len(server.requests)
        assert result('setup.checkUpdate')['result']['updateAvailable'] is False
        bridge.call('preferences.set', dict(key='offlineMode', value=True))
        result('setup.install', expected='offline')
        assert len(server.requests) == before
        bridge.call('preferences.set', dict(key='offlineMode', value=False))
        report['steps'].append('offline-and-disabled-automatic-check-perform-zero-http-requests')
        server.publish('0.1.8')
        server.delay_archive = True
        server.archive_started.clear()
        job = bridge.call('setup.install', {})['result']['jobID']
        assert server.archive_started.wait(timeout=15)
        bridge.call('jobs.cancel', dict(jobID=job))
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            value = bridge.call('jobs.get', dict(jobID=job))['result']
            if value['status'] == 'cancelled':
                break
            time.sleep(0.02)
        assert value['status'] == 'cancelled', value
        assert bridge.call('setup.status', {})['result']['path'] == updated
        server.delay_archive = False
        report['steps'].append('cancellation-of-real-urlsession-download-preserves-current-runtime-and-responsive-bridge')
        bridge.close()
        bridge = None
        if args.real_release:
            actual = dict(env, XDG_DATA_HOME=str(fixture / 'Published Runtime'))
            actual.pop('WHISKY_LINUX_WINE_RELEASES_URL')
            bridge = start(actual)
            installed = result('setup.install', timeout=600)['result']
            assert installed['installed'] and installed['managed']
            assert Path(installed['path']).joinpath('run').is_file()
            report['publishedRuntime'] = installed
            report['publishedRecord'] = json.loads(Path(installed['path']).parent.joinpath('release.json').read_text())
            report['steps'].append('published-github-linux-release-real-download-hash-manifest-elf-and-archive-validation')
        report['passed'] = True
    finally:
        server.delay_archive = False
        if bridge:
            bridge.close()
        server.close()
        (output / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        log.close()
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
