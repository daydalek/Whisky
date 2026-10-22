#!/usr/bin/env python3
"""Verify owned tar/gzip shutdown, cancellation and recovery using real helpers."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import runpy
import signal
import subprocess
import tarfile
import tempfile
import time


def group_members(group):
    members = []
    for path in Path('/proc').iterdir():
        if not path.name.isdigit():
            continue
        try:
            stat = (path / 'stat').read_text()
            end = stat.rindex(')')
            fields = stat[end + 1:].split()
            if int(fields[2]) == group and fields[0] not in ('Z', 'X'):
                members.append({'pid': int(path.name), 'name': stat[stat.index('(') + 1:end]})
        except (FileNotFoundError, ProcessLookupError):
            continue
    return members


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', type=Path, required=True)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    support = runpy.run_path(str(Path(__file__).with_name('check-recovery.py')))
    Helper, read_plist = support['Helper'], support['read_plist']
    root = Path(tempfile.mkdtemp(prefix='fixture-', dir=output))
    source, game, registry, _ = runpy.run_path(str(Path(__file__).with_name('check-programs.py')))['fixture_at'](root)
    payload = source / 'archive-payload.bin'
    with payload.open('wb') as file:
        for _ in range(16):
            file.write(os.urandom(2 * 1024 * 1024))
    digest = hashlib.sha256(payload.read_bytes()).hexdigest()
    original_registry = registry.read_bytes()
    original_metadata = (source / 'Metadata.plist').read_bytes()
    env = dict(os.environ, WHISKY_REGISTRY=str(registry), XDG_CONFIG_HOME=str(root / 'config'),
               XDG_DATA_HOME=str(root / 'data'), XDG_STATE_HOME=str(root / 'state'))
    journal_path = registry.with_suffix('.plist.export.plist')
    report = {'steps': [], 'passed': False, 'fixture': str(root)}
    log = (output / 'helper.log').open('w')
    active = None

    def start_export(destination):
        started = active.call('bottle.export', dict(container=str(source), destination=str(destination)))
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            journal = read_plist(journal_path)
            if journal and journal.get('child') and not journal['prepared']:
                group = journal['child']['pid']
                members = group_members(group)
                if any(member['name'] == 'gzip' for member in members):
                    return started, journal, members
            time.sleep(0.001)
        raise AssertionError('No live owned gzip process was observed')

    try:
        active = Helper(args.helper.resolve(), env, log)
        destination = root / 'interrupted.tar'
        started, observed, members = start_export(destination)
        (output / 'observed-export.plist').write_bytes(plistlib.dumps(observed))
        report['ownedGroupBeforeKill'] = members
        active.process.kill()
        assert active.process.wait(timeout=10) == -signal.SIGKILL
        deadline = time.monotonic() + 10
        while group_members(observed['child']['pid']) and time.monotonic() < deadline:
            time.sleep(0.01)
        assert group_members(observed['child']['pid']) == [], 'Exporter or compression child survived its bridge'
        report['steps'].append('sigkill-bridge-terminates-observed-supervisor-tar-and-gzip-group')
        cli_env = dict(env, WHISKY_BRIDGE_HELPER=str(args.helper.resolve()), WHISKY_BRIDGE_NO_WINE='1')
        cli = subprocess.run([str(args.binary.resolve()), '--print-library', '--all'], env=cli_env,
                             capture_output=True, text=True, timeout=40)
        assert cli.returncode == 0, cli.stderr
        assert not journal_path.exists() and not destination.exists()
        assert list(root.glob('.whisky-export-*')) == []
        report['steps'].append('production-client-restart-removes-owned-partial-archive-and-clears-journal')

        active = Helper(args.helper.resolve(), env, log)
        destination = root / 'cancelled.tar'
        started, observed, _ = start_export(destination)
        active.call('jobs.cancel', dict(jobID=started['jobID']))
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            state = active.call('jobs.get', dict(jobID=started['jobID']))
            if state['status'] == 'cancelled':
                break
            assert state['status'] in ('running', 'cancelling'), state
            time.sleep(0.01)
        else:
            raise AssertionError('Export cancellation did not unwind')
        assert not journal_path.exists() and not destination.exists()
        assert group_members(observed['child']['pid']) == []
        assert list(root.glob('.whisky-export-*')) == []
        report['steps'].append('cancel-active-export-stops-owned-group-and-removes-partial-output')

        destination = root / 'completed.tar'
        result = active.job(active.call('bottle.export', dict(container=str(source), destination=str(destination))))
        assert result['path'] == str(destination)
        with tarfile.open(destination, 'r:gz') as archive:
            assert hashlib.sha256(archive.extractfile(source.name + '/archive-payload.bin').read()).hexdigest() == digest
            assert archive.extractfile(source.name + '/' + str(game.relative_to(source))).read() == b'MZ fixture'
        assert not journal_path.exists() and list(root.glob('.whisky-export-*')) == []
        assert registry.read_bytes() == original_registry
        assert (source / 'Metadata.plist').read_bytes() == original_metadata
        assert hashlib.sha256(payload.read_bytes()).hexdigest() == digest
        report['steps'].append('completed-gzip-archive-valid-and-source-bytes-and-registry-retained')
        active.stop()
        active = None
        report['passed'] = True
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        if active is not None and active.process.poll() is None:
            active.process.kill()
            active.process.wait(timeout=10)
        log.close()
        (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
