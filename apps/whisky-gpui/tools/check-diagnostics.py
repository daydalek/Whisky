#!/usr/bin/env python3
"""Verify Linux file diagnostics with real isolated helper processes."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import plistlib
import runpy
import select
import subprocess
import tempfile
import time


class Bridge:
    def __init__(self, helper, env, log):
        self.process = subprocess.Popen([str(helper)], env=env, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=log, text=True)
        self.sequence = 0

    def call(self, method, params):
        self.sequence += 1
        self.process.stdin.write(json.dumps(dict(version=1, id=str(self.sequence), method=method, params=params)) + '\n')
        self.process.stdin.flush()
        assert select.select([self.process.stdout], [], [], 15)[0], 'Helper response timed out'
        reply = json.loads(self.process.stdout.readline())
        assert reply['id'] == str(self.sequence), reply
        return reply

    def run(self, method, params):
        reply = self.call(method, params)
        if reply.get('error'):
            return reply
        job = reply['result']['jobID']
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            state = self.call('jobs.get', dict(jobID=job))['result']
            if state['status'] == 'completed':
                return dict(result=state['result'])
            if state['status'] in ('failed', 'cancelled'):
                return dict(error=state['error'])
            time.sleep(0.02)
        raise AssertionError('Diagnostics job timed out')

    def close(self):
        try:
            self.call('bridge.shutdown', {})
            assert self.process.wait(timeout=10) == 0
        finally:
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix='fixture-', dir=output))
    generator = runpy.run_path(str(Path(__file__).with_name('check-programs.py')))['fixture_at']
    bottle, executable, registry, identity = generator(root)
    env = dict(os.environ, WHISKY_REGISTRY=str(registry), WHISKY_BRIDGE_NO_WINE='1',
               XDG_CONFIG_HOME=str(root / 'config'), XDG_DATA_HOME=str(root / 'data'),
               DIAGNOSTICS_SECRET='fixture-secret-must-stay-private')
    source = {str(path.relative_to(bottle)): hashlib.sha256(path.read_bytes()).hexdigest()
              for path in bottle.rglob('*') if path.is_file()}
    before_registry = registry.read_bytes()
    params = dict(container=str(bottle))
    report = {'passed': False, 'steps': [], 'fixture': str(root)}
    with (output / 'helper.log').open('w') as log:
        bridge = Bridge(args.helper.resolve(), env, log)
        try:
            describe = bridge.call('bridge.describe', {})['result']
            assert 'bottle.diagnostics.file' in describe['capabilities'], describe
            assert {'bottle.diagnostics', 'bottle.checks', 'bottle.exportDiagnostics'}.issubset(describe['methods'])
            assert 'audio.test' not in describe['methods']
            value = bridge.run('bottle.diagnostics', params)['result']['report']
            assert 'Platform: linux' in value and 'Distribution:' in value and 'Architecture:' in value
            assert 'Pinned entries: 1' in value and 'fixture-secret' not in value
            assert '--legacy' not in value and 'CUSTOM' not in value
            checks = bridge.run('bottle.checks', params)['result']['checks']
            assert len(checks) == 4 and all(check['outcome'] in ('pass', 'warning') for check in checks), checks
            report['steps'].append('real-host-report-and-platform-file-checks-omit-environment-and-program-secrets')
            destination = root / '并发 report.txt'

            def export():
                other = Bridge(args.helper.resolve(), env, log)
                try:
                    return other.run('bottle.exportDiagnostics', dict(params, destination=str(destination)))
                finally:
                    other.close()

            with ThreadPoolExecutor(max_workers=2) as pool:
                results = list(pool.map(lambda _: export(), range(2)))
            assert sum('result' in item for item in results) == 1, results
            assert sum(item.get('error', {}).get('code') == 'destination_exists' for item in results) == 1, results
            exported = destination.read_text()
            assert exported.startswith('Whisky file diagnostics v1\n')
            assert 'File checks\n' in exported and 'host.storage:' in exported
            assert 'Name: Portable Fixture' in exported and 'fixture-secret' not in exported
            assert destination.stat().st_mode & 0o777 == 0o600
            assert not list(root.glob('.whisky-diagnostics-*'))
            report['steps'].append('independent-process-exports-publish-one-complete-private-report-without-overwrite')
            # Invalid marker types produce a warning through the real protocol.
            marker = bottle / 'Metadata.plist'
            original = marker.read_bytes()
            marker.unlink()
            os.mkfifo(marker)
            bad = bridge.run('bottle.diagnostics', params)['result']['report']
            assert 'host.container_metadata: warning' in bad
            marker.unlink()
            marker.write_bytes(original)
            report['steps'].append('fifo-metadata-returns-bounded-warning-through-production-helper')
            after = {str(path.relative_to(bottle)): hashlib.sha256(path.read_bytes()).hexdigest()
                     for path in bottle.rglob('*') if path.is_file()}
            assert source == after and before_registry == registry.read_bytes()
            report['steps'].append('container-file-hashes-and-registry-bytes-retained')
            report['passed'] = True
        finally:
            bridge.close()
            (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
