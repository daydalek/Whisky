#!/usr/bin/env python3
"""Exercise native-format program storage through real, independent helper processes."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import uuid


def fixture_at(root):
    bottle = root / 'Bottle'
    executable = bottle / 'drive_c/Program Files/Game/game.exe'
    executable.parent.mkdir(parents=True)
    executable.write_bytes(b'MZ fixture')
    metadata = {'info': {'name': 'Portable Fixture', 'pins': [
        {'name': 'Portable Game', 'url': {'relative': executable.as_uri()}, 'removable': False}
    ], 'blocklist': []}, 'dxvkConfig': {'dxvk': True}, 'future': {'keep': 'opaque'}}
    (bottle / 'Metadata.plist').write_bytes(plistlib.dumps(metadata))
    registry = root / 'BottleVM.plist'
    registry.write_bytes(plistlib.dumps({'paths': [{'relative': bottle.as_uri()}]}))
    directory = bottle / 'Program Settings'
    directory.mkdir()
    (directory / 'game.exe.plist').write_bytes(plistlib.dumps({
        'arguments': '--legacy', 'environment': {'CUSTOM': 'retained'}, 'future': {'keep': 'opaque'}
    }))
    key = hashlib.sha256(b'/drive_c/Program Files/Game/game.exe').hexdigest()[:8]
    return bottle, executable, registry, directory / f'game-{key}.plist'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix='fixture-', dir=output))
    bottle, executable, registry, identity = fixture_at(root)
    env = dict(os.environ, WHISKY_REGISTRY=str(registry), XDG_CONFIG_HOME=str(root / 'config'),
               XDG_STATE_HOME=str(root / 'state'), XDG_DATA_HOME=str(root / 'data'))
    params = dict(container=str(bottle), executable=str(executable))
    report = {'fixture': str(root), 'steps': [], 'passed': False}

    def request(method, extra=None, error=None):
        frames = [dict(version=1, id='call', method=method, params=dict(params, **(extra or {}))),
                  dict(version=1, id='stop', method='bridge.shutdown', params={})]
        result = subprocess.run([str(args.helper.resolve())], env=env, text=True,
                                input=''.join(json.dumps(frame) + '\n' for frame in frames),
                                capture_output=True, check=True, timeout=20)
        replies = [json.loads(line) for line in result.stdout.splitlines()]
        assert len(replies) == 2 and replies[0]['id'] == 'call', replies
        reply = replies[0]
        if error:
            assert reply['error']['code'] == error, reply
        else:
            assert reply.get('error') is None, reply
        return reply.get('result')

    try:
        read = request('programs.settings.read')
        assert read['arguments'] == '--legacy' and read['defaults']['graphicsBackend'] == 'dxvk', read
        assert not identity.exists(), 'Read materialized identity settings'
        report['steps'].append('registry-and-legacy-read')
        patch = dict(locale='ja_JP.UTF-8', arguments='--portable 中文 $HOME', overrides={
            'graphicsBackend': 'dxvk', 'dxvkHud': 'fps', 'enhancedSync': 'esync',
            'virtualDesktopEnabled': True, 'customResolutionWidth': 1280, 'customResolutionHeight': 720,
            'dllOverrides': [dict(dllName='dxgi', mode='n,b')], 'taggedVerbs': ['vcrun2022']})
        request('programs.settings.set', dict(patch=patch))
        restarted = request('programs.settings.read')
        assert restarted['arguments'] == patch['arguments'] and restarted['overrides'] == patch['overrides'], restarted
        assert restarted['environment']['LANG'] == 'ja_JP.UTF-8', restarted
        assert plistlib.loads(identity.read_bytes())['future'] == {'keep': 'opaque'}
        report['steps'].append('complete-settings-write-and-process-restart')
        edits = [dict(overrides={key: value}) for key, value in dict(
            dxvkAsync=False, shaderCacheEnabled=False, disableHIDAPI=True, useButtonLabels=True,
            allowBackgroundEvents=True, disableControllerMapping=True).items()]
        with ThreadPoolExecutor(max_workers=6) as pool:
            list(pool.map(lambda patch: request('programs.settings.set', dict(patch=patch)), edits))
        read = request('programs.settings.read')
        for patch in edits:
            for key, value in patch['overrides'].items():
                assert read['overrides'][key] == value, read
        report['steps'].append('six-concurrent-helper-writers-retain-disjoint-edits')
        original = identity.read_bytes()
        request('programs.settings.set', dict(patch=dict(arguments='bad', overrides={'dxvk': 1})), error='invalid_params')
        assert identity.read_bytes() == original
        report['steps'].append('invalid-patch-preserves-file')
        logs = root / 'state/whisky/logs'
        logs.mkdir(parents=True)
        runs = [dict(id=str(uuid.uuid4()).upper(), startTime=datetime(2026, 1, 1),
                     endTime=datetime(2026, 1, 1, 0, 0, 5), programName='game.exe',
                     logFileName=f'run-{index}.log', exitCode=0, futureEntry=True) for index in range(2)]
        history = bottle / 'Program Settings/game.exe.run-history.plist'
        history.write_bytes(plistlib.dumps(dict(entries=runs, futureHistory='opaque')))
        for run in runs:
            (logs / run['logFileName']).write_text('fixture log')
        read = request('programs.history.read')
        assert len(read['entries']) == 2 and read['entries'][0]['duration'] == 5, read
        remaining = request('programs.history.delete', dict(runID=runs[0]['id']))
        assert len(remaining['entries']) == 1 and remaining['entries'][0]['id'] == runs[1]['id'], remaining
        assert not (logs / runs[0]['logFileName']).exists()
        assert (logs / runs[1]['logFileName']).exists()
        assert plistlib.loads(history.read_bytes())['futureHistory'] == 'opaque'
        report['steps'].append('imported-history-read-selective-delete-and-log-cleanup')
        report['passed'] = True
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
