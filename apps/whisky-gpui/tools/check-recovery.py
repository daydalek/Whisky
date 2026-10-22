#!/usr/bin/env python3
"""SIGKILL real helpers at observed lifecycle boundaries; recover isolated trees."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import runpy
import select
import shutil
import signal
import subprocess
import tempfile
import time


class Helper:
    def __init__(self, executable, environment, log):
        self.process = subprocess.Popen([str(executable)], env=environment, text=True, bufsize=1,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)
        self.sequence = 0
        self.call('bridge.describe')

    def call(self, method, params=None):
        self.sequence += 1
        self.process.stdin.write(json.dumps(dict(version=1, id=str(self.sequence), method=method, params=params or {})) + '\n')
        self.process.stdin.flush()
        assert select.select([self.process.stdout], [], [], 20)[0], f'{method} reply timed out'
        reply = json.loads(self.process.stdout.readline())
        assert reply['id'] == str(self.sequence) and reply.get('error') is None, reply
        return reply['result']

    def job(self, started):
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            state = self.call('jobs.get', dict(jobID=started['jobID']))
            if state['status'] == 'completed':
                return state['result']
            assert state['status'] in ('queued', 'running', 'cancelling'), state
            time.sleep(0.01)
        raise AssertionError('Recovery job timed out')

    def stop(self):
        if self.process.poll() is None:
            self.call('bridge.shutdown')
            assert self.process.wait(timeout=10) == 0


def read_plist(path):
    try:
        return plistlib.loads(path.read_bytes())
    except FileNotFoundError:
        return None


def native_url(value):
    from urllib.parse import unquote, urlparse
    return Path(unquote(urlparse(value['relative']).path))


def interrupt_copy(executable, source, registry, environment, log):
    """Leave one observed, uncommitted copy for a production-window startup."""
    bulk = source / 'startup-recovery-fixture'
    bulk.mkdir()
    for index in range(2500):
        (bulk / f'{index:04}.bin').write_bytes(b'owned fixture' * 64)
    helper = Helper(executable, environment, log)
    journal_path = registry.with_suffix('.plist.lifecycle.plist')
    try:
        helper.call('bottle.duplicate', dict(container=str(source), name='Interrupted startup clone'))
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            assert helper.process.poll() is None
            journal = read_plist(journal_path)
            if journal:
                destination = native_url(journal['destination'])
                if destination.exists() and any(destination.iterdir()):
                    os.kill(helper.process.pid, signal.SIGSTOP)
                    stop_deadline = time.monotonic() + 2
                    while time.monotonic() < stop_deadline:
                        if '\nState:\tT' in Path(f'/proc/{helper.process.pid}/status').read_text():
                            break
                        time.sleep(0.001)
                    frozen = read_plist(journal_path)
                    assert frozen is not None
                    assert read_plist(registry).get('whiskyLifecycleCommit') != frozen['id']
                    helper.process.kill()
                    assert helper.process.wait(timeout=10) == -signal.SIGKILL
                    return native_url(frozen['destination'])
            time.sleep(0.001)
        raise AssertionError('Startup fixture did not reach an active copy')
    finally:
        if helper.process.poll() is None:
            helper.process.kill()
            helper.process.wait(timeout=10)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', required=True, type=Path)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    generator = runpy.run_path(str(Path(__file__).with_name('check-programs.py')))['fixture_at']
    report = {'steps': [], 'passed': False}
    log = (output / 'helper.log').open('w')
    active = None
    cross_parent = None
    try:
        for scenario in ['duplicate-before-commit', 'move-before-commit', 'remove-after-commit', 'cross-move-after-commit']:
            root = Path(tempfile.mkdtemp(prefix=scenario + '-', dir=output))
            source, executable, registry, _ = generator(root)
            original_metadata = (source / 'Metadata.plist').read_bytes()
            env = dict(os.environ, WHISKY_REGISTRY=str(registry), XDG_CONFIG_HOME=str(root / 'config'),
                       XDG_DATA_HOME=str(root / 'data'), XDG_STATE_HOME=str(root / 'state'), WHISKY_BRIDGE_NO_WINE='1')
            bulk = source / 'bulk'
            bulk.mkdir()
            for index in range(3000):
                if scenario == 'move-before-commit':
                    (bulk / f'{index:04}').symlink_to(executable)
                else:
                    (bulk / f'{index:04}').write_bytes(b'owned fixture' * 64)
            outside = root / 'external-data'
            outside.write_text('external data stays intact')
            (source / 'external').symlink_to(outside)
            active = Helper(args.helper.resolve(), env, log)
            journal_path = registry.with_suffix('.plist.lifecycle.plist')
            if scenario.startswith('duplicate'):
                started = active.call('bottle.duplicate', dict(container=str(source), name='Interrupted clone'))
            elif scenario.startswith('remove'):
                started = active.call('bottle.remove', dict(container=str(source), deleteFiles=True))
            else:
                parent = root / 'Moved'
                if scenario.startswith('cross'):
                    base = Path(tempfile.gettempdir())
                    if base.stat().st_dev == source.stat().st_dev:
                        base = Path('/dev/shm')
                    assert base.stat().st_dev != source.stat().st_dev
                    cross_parent = Path(tempfile.mkdtemp(prefix='whisky-recovery-', dir=base))
                    parent = cross_parent
                else:
                    parent.mkdir()
                started = active.call('bottle.move', dict(container=str(source), destination=str(parent)))
            deadline = time.monotonic() + 30
            observed = None
            while time.monotonic() < deadline:
                assert active.process.poll() is None, 'Helper exited before the observed interruption'
                journal = read_plist(journal_path)
                document = read_plist(registry)
                if journal and document:
                    committed = document.get('whiskyLifecycleCommit') == journal['id']
                    destination = native_url(journal['destination'])
                    if scenario == 'duplicate-before-commit':
                        ready = not committed and destination.exists() and any(destination.iterdir())
                    elif scenario == 'move-before-commit':
                        ready = not committed and not source.exists() and destination.exists()
                    else:
                        ready = committed and destination.exists() and (source.exists() if scenario.startswith('cross') else True)
                    if ready:
                        # Group-stop freezes every helper thread before examining the
                        # authoritative commit state and delivering the terminal kill.
                        os.kill(active.process.pid, signal.SIGSTOP)
                        status = Path(f'/proc/{active.process.pid}/status')
                        stop_deadline = time.monotonic() + 2
                        while time.monotonic() < stop_deadline:
                            if '\nState:\tT' in status.read_text():
                                break
                            time.sleep(0.001)
                        frozen_journal = read_plist(journal_path)
                        frozen_registry = read_plist(registry)
                        assert frozen_journal is not None, 'Operation completed before it could be frozen'
                        frozen_commit = frozen_registry.get('whiskyLifecycleCommit') == frozen_journal['id']
                        assert frozen_commit == scenario.endswith('after-commit'), (scenario, frozen_commit)
                        observed = frozen_journal
                        active.process.kill()
                        assert active.process.wait(timeout=10) == -signal.SIGKILL
                        break
                time.sleep(0.001)
            assert observed is not None, f'{scenario} never reached its intended boundary'
            destination = native_url(observed['destination'])
            (root / 'observed-journal.plist').write_bytes(plistlib.dumps(observed))
            if scenario == 'duplicate-before-commit':
                # The production client invokes workspace.recover before its first
                # catalogue read. No fixture-side repair happens before this call.
                cli_env = dict(env, WHISKY_BRIDGE_HELPER=str(args.helper.resolve()))
                result = subprocess.run([str(args.binary.resolve()), '--print-library', '--all'],
                                        env=cli_env, capture_output=True, text=True, timeout=45)
                assert result.returncode == 0, result.stderr
                (root / 'production-library.json').write_text(result.stdout)
                report['steps'].append('production-client-startup-recovers-killed-copy-before-catalogue-load')
            active = Helper(args.helper.resolve(), env, log)
            if journal_path.exists():
                active.job(active.call('workspace.recover'))
            assert not journal_path.exists(), 'Recovery retained its journal after success'
            containers = active.call('workspace.containers')
            if scenario in ('duplicate-before-commit', 'move-before-commit'):
                assert len(containers) == 1 and containers[0]['path'] == str(source), containers
                assert (source / 'Metadata.plist').read_bytes() == original_metadata
                assert not destination.exists()
                assert len(list((source / 'bulk').iterdir())) == 3000
                if scenario == 'move-before-commit':
                    assert all(link.readlink() == executable for link in (source / 'bulk').iterdir())
            elif scenario == 'remove-after-commit':
                assert containers == [] and not source.exists() and not destination.exists(), containers
            else:
                assert len(containers) == 1 and containers[0]['path'] == str(destination), containers
                assert not source.exists()
                assert (destination / executable.relative_to(source)).read_bytes() == b'MZ fixture'
                assert len(list((destination / 'bulk').iterdir())) == 3000
            assert outside.read_text() == 'external data stays intact'
            report['steps'].append(scenario + '-sigkill-and-fresh-helper-recovery')
            active.stop()
            active = None
            if cross_parent is not None:
                shutil.rmtree(cross_parent)
                cross_parent = None
        report['passed'] = True
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        if active is not None and active.process.poll() is None:
            active.process.kill()
            active.process.wait(timeout=10)
        if cross_parent is not None:
            # On failure, keep the only complete cross-device copy as evidence.
            report['retainedCrossDeviceFixture'] = str(cross_parent)
        log.close()
        (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
