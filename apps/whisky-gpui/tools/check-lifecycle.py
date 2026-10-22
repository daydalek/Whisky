#!/usr/bin/env python3
"""Exercise file lifecycle through the real helper with isolated prefixes only."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import plistlib
import runpy
import select
import shutil
import subprocess
import tarfile
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix='fixture-', dir=output))
    generator = runpy.run_path(str(Path(__file__).with_name('check-programs.py')))['fixture_at']
    source, executable, registry, _ = generator(root)
    outside = root / 'external'
    outside.mkdir()
    (outside / 'keep').write_text('external data')
    (source / 'external').symlink_to(outside, target_is_directory=True)
    (source / 'internal').symlink_to(executable)
    for relative in ['logs/old.log', 'drive_c/Game/logs/keep.log', 'old.diagnosis-history.plist']:
        path = source / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('retain in source')
    (source / 'Folder Games.json').write_text(json.dumps(dict(
        roots=[str(source / 'drive_c')], executables={'drive_c/Game': 'drive_c/Game/game.exe'},
        automaticMetadata=False, future={'retain': True})))
    document = plistlib.loads(registry.read_bytes())
    document['futureRegistry'] = {'retain': True}
    registry.write_bytes(plistlib.dumps(document))
    original_game = executable.read_bytes()
    env = dict(os.environ, WHISKY_REGISTRY=str(registry), XDG_CONFIG_HOME=str(root / 'config'),
               XDG_DATA_HOME=str(root / 'data'), XDG_STATE_HOME=str(root / 'state'))
    log = (output / 'helper.log').open('w')
    report = {'steps': [], 'fixture': str(root), 'passed': False}
    cross_base = Path(tempfile.gettempdir())
    if cross_base.stat().st_dev == source.stat().st_dev:
        cross_base = Path('/dev/shm')
    assert cross_base.stat().st_dev != source.stat().st_dev, 'A second filesystem is required for the move gate'
    cross_parent = Path(tempfile.mkdtemp(prefix='whisky-lifecycle-cross-', dir=cross_base))
    helper = None
    sequence = 0

    def start():
        nonlocal helper
        helper = subprocess.Popen([str(args.helper.resolve())], env=env, text=True, bufsize=1,
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)

    def request(method, params=None, error=None):
        nonlocal sequence
        sequence += 1
        helper.stdin.write(json.dumps(dict(version=1, id=str(sequence), method=method, params=params or {})) + '\n')
        helper.stdin.flush()
        assert select.select([helper.stdout], [], [], 20)[0], f'{method} response timed out'
        reply = json.loads(helper.stdout.readline())
        assert reply['id'] == str(sequence), reply
        if error:
            assert reply['error']['code'] == error, reply
        else:
            assert reply.get('error') is None, reply
        return reply.get('result')

    def finish(method, path, **params):
        result = request(method, dict(container=str(path), **params))
        if 'jobID' not in result:
            return result
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            state = request('jobs.get', dict(jobID=result['jobID']))
            if state['status'] == 'completed':
                return state['result']
            assert state['status'] not in ('failed', 'cancelled'), state
            time.sleep(0.02)
        raise AssertionError(f'{method} job timed out')

    def restart():
        request('bridge.shutdown')
        assert helper.wait(timeout=10) == 0
        start()
        return request('workspace.containers')

    try:
        start()
        description = request('bridge.describe')
        assert 'bottle.lifecycle.file' in description['capabilities'], description
        finish('bottle.rename', source, name='Linux 中文 $HOME')
        assert restart()[0]['name'] == 'Linux 中文 $HOME'
        source_metadata = (source / 'Metadata.plist').read_bytes()
        report['steps'].append('rename-persists-across-real-helper-restart')

        clone = Path(finish('bottle.duplicate', source, name='Clone')['path'])
        assert (clone / 'internal').readlink() == clone / executable.relative_to(source)
        assert (clone / 'external').readlink() == outside
        assert not (clone / 'logs/old.log').exists()
        assert not (clone / 'old.diagnosis-history.plist').exists()
        assert (clone / 'drive_c/Game/logs/keep.log').exists()
        assert (source / 'Metadata.plist').read_bytes() == source_metadata
        assert len(restart()) == 2
        report['steps'].append('clone-remaps-owned-paths-and-retains-external-data-and-nested-logs')

        parent = root / 'Moved'
        parent.mkdir()
        alias = root / 'Moved alias'
        alias.symlink_to(parent, target_is_directory=True)
        clone = Path(finish('bottle.move', clone, destination=str(alias))['path'])
        assert clone.parent == parent
        assert (clone / 'internal').readlink() == clone / executable.relative_to(source)
        assert {entry['path'] for entry in restart()} == {str(source), str(clone)}
        report['steps'].append('same-filesystem-move-canonicalizes-parent-alias-and-reloads-registry')

        assert clone.stat().st_dev != cross_parent.stat().st_dev, 'Cross-device fixture needs another filesystem'
        # Cross-device moves preserve transient files as well as game data.
        (clone / 'logs/move.log').write_text('preserve during move')
        old_clone = clone
        clone = Path(finish('bottle.move', clone, destination=str(cross_parent))['path'])
        assert not old_clone.exists() and clone.exists()
        assert (clone / 'logs/move.log').read_text() == 'preserve during move'
        assert (clone / 'internal').readlink() == clone / executable.relative_to(source)
        assert str(clone) in {entry['path'] for entry in restart()}
        report['steps'].append('cross-device-move-preserves-complete-tree-and-updates-links')

        archive = root / '导出 $HOME.tar'
        finish('bottle.export', clone, destination=str(archive))
        with tarfile.open(archive, 'r:gz') as tar:
            members = tar.getmembers()
            assert all(member.name == clone.name or member.name.startswith(clone.name + '/') for member in members)
            assert tar.getmember(clone.name + '/external').issym()
            assert tar.extractfile(clone.name + '/' + str(executable.relative_to(source))).read() == original_game
        report['steps'].append('gzip-tar-export-has-relative-members-and-preserves-symlinks')

        with registry.with_suffix('.plist.lock').open('a') as lease:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
            request('bottle.rename', dict(container=str(source), name='Busy'), error='busy')
        report['steps'].append('independent-process-registry-lease-prevents-conflicting-mutations')

        bulk = source / 'copy-cancellation-fixture'
        bulk.mkdir()
        for index in range(1500):
            (bulk / f'{index:04}.bin').write_bytes(b'fixture' * 128)
        before_names = {entry.name for entry in root.iterdir()}
        started = request('bottle.duplicate', dict(container=str(source), name='Cancelled clone'))
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if {entry.name for entry in root.iterdir()} - before_names:
                break
            time.sleep(0.005)
        else:
            raise AssertionError('Clone never began copying')
        request('jobs.cancel', dict(jobID=started['jobID']))
        while time.monotonic() < deadline:
            state = request('jobs.get', dict(jobID=started['jobID']))
            if state['status'] == 'cancelled':
                break
            assert state['status'] in ('running', 'cancelling'), state
            time.sleep(0.01)
        else:
            raise AssertionError('Copy cancellation did not unwind')
        assert {entry.name for entry in root.iterdir()} == before_names
        assert len(list(bulk.iterdir())) == 1500
        assert len(restart()) == 2
        report['steps'].append('cancel-active-copy-cleans-owned-partial-clone-and-retains-source')

        finish('bottle.remove', clone)
        assert clone.exists() and len(restart()) == 1
        document = plistlib.loads(registry.read_bytes())
        document['paths'].append(dict(relative=clone.as_uri()))
        registry.write_bytes(plistlib.dumps(document))
        finish('bottle.remove', clone, deleteFiles=True)
        assert not clone.exists() and len(restart()) == 1
        assert (outside / 'keep').read_text() == 'external data'
        assert executable.read_bytes() == original_game
        assert (source / 'Metadata.plist').read_bytes() == source_metadata
        assert plistlib.loads(registry.read_bytes())['futureRegistry'] == {'retain': True}
        report['steps'].append('deregister-retains-files-and-delete-preserves-external-symlink-targets')
        request('bridge.shutdown')
        assert helper.wait(timeout=10) == 0
        report['passed'] = True
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        if helper is not None and helper.poll() is None:
            helper.terminate()
            try:
                helper.wait(timeout=5)
            except subprocess.TimeoutExpired:
                helper.kill()
                helper.wait()
        # Only this run's mkdtemp tree on the separate filesystem is owned here.
        shutil.rmtree(cross_parent)
        log.close()
        (output / 'report.json').write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
    print(json.dumps(report, indent=2, ensure_ascii=False))


if __name__ == '__main__':
    main()
