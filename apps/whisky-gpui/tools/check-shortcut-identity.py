#!/usr/bin/env python3
"""Follow one unchanged desktop shortcut through real same/cross-device lifecycle jobs."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import runpy
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix='fixture-', dir=output))
    tools = Path(__file__).parent
    bottle, executable, registry, identity = runpy.run_path(str(tools / 'check-programs.py'))['fixture_at'](root)
    launcher = root / 'frontend'
    launcher.write_text('#!/bin/sh\nexit 0\n')
    launcher.chmod(0o700)
    env = dict(os.environ, WHISKY_REGISTRY=str(registry), XDG_DATA_HOME=str(root / 'data'),
               XDG_CONFIG_HOME=str(root / 'config'))
    bridge_type = runpy.run_path(str(tools / 'check-diagnostics.py'))['Bridge']
    report = {'passed': False, 'steps': [], 'fixture': str(root)}
    cross = Path(tempfile.mkdtemp(prefix='whisky-shortcut-', dir='/dev/shm'))
    with (output / 'helper.log').open('w') as log:
        bridge = bridge_type(args.helper.resolve(), env, log)
        try:
            created = bridge.call('programs.shortcut.create', dict(container=str(bottle), executable=str(executable),
                launcher=str(launcher), destination=str(root)))
            assert created.get('error') is None, created
            created = created['result']
            shortcut = Path(created['path'])
            shortcut_bytes = shortcut.read_bytes()
            reference = dict(containerID=created['containerID'], path=created['programPath'])
            original = dict(reference)
            def resolve(expected):
                reply = bridge.call('system.desktop.resolve', reference)
                assert reply.get('error') is None, reply
                assert Path(reply['result']['container']) == expected, reply
                assert Path(reply['result']['path']) == expected / 'drive_c/Program Files/Game/game.exe', reply
                assert shortcut.read_bytes() == shortcut_bytes
                assert reference == original
            resolve(bottle)
            parent = root / 'Moved 中文'
            parent.mkdir()
            moved = bridge.run('bottle.move', dict(container=str(bottle), destination=str(parent)))
            assert moved.get('error') is None, moved
            current = parent / bottle.name
            resolve(current)
            report['steps'].append('unchanged-id-and-desktop-bytes-resolve-after-same-device-move')
            assert cross.stat().st_dev != current.stat().st_dev
            moved = bridge.run('bottle.move', dict(container=str(current), destination=str(cross)))
            assert moved.get('error') is None, moved
            current = cross / current.name
            resolve(current)
            bridge.close()
            bridge = bridge_type(args.helper.resolve(), env, log)
            resolve(current)
            report['steps'].append('cross-device-move-updates-directory-identity-and-survives-helper-restart')
            clone = bridge.run('bottle.duplicate', dict(container=str(current), name='Independent clone'))
            assert clone.get('error') is None, clone
            clone = Path(clone['result']['path'])
            other = bridge.call('programs.shortcut.create', dict(container=str(clone),
                executable=str(clone / 'drive_c/Program Files/Game/game.exe'), launcher=str(launcher),
                destination=str(root), name='Clone'))
            assert other['result']['containerID'] != reference['containerID'], other
            resolve(current)
            assert bridge.run('bottle.remove', dict(container=str(current), deleteFiles=False)).get('error') is None
            assert bridge.call('system.desktop.resolve', reference)['error']['code'] == 'shortcut_unavailable'
            assert bridge.call('workspace.import', dict(path=str(current))).get('error') is None
            resolve(current)
            assert bridge.run('bottle.remove', dict(container=str(current), deleteFiles=True)).get('error') is None
            assert bridge.call('system.desktop.resolve', reference)['error']['code'] == 'shortcut_unavailable'
            assert reference['containerID'] not in plistlib.loads(registry.read_bytes())['whiskyContainerIdentities']
            assert shortcut.read_bytes() == shortcut_bytes
            report['steps'].append('clone-is-independent-deregistration-reimport-retains-id-and-physical-delete-prunes-id')
            report['passed'] = True
        finally:
            bridge.close()
            shutil.rmtree(cross)
            (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
