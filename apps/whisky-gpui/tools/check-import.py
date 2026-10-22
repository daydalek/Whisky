#!/usr/bin/env python3
"""Discover and register isolated existing prefixes through independent helpers."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import plistlib
import runpy
import shutil
import subprocess
import tempfile
import time


def snapshot(root):
    result = {}
    for directory, directories, files in os.walk(root, followlinks=False):
        for name in directories + files:
            path = Path(directory) / name
            if path.is_symlink():
                result[str(path.relative_to(root))] = ['symlink', str(path.readlink())]
            elif path.is_file():
                result[str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix='fixture-', dir=output))
    source, _, registry, _ = runpy.run_path(str(Path(__file__).with_name('check-programs.py')))['fixture_at'](root)
    second = root / 'Second'
    shutil.copytree(source, second, symlinks=True)
    alias = root / 'Alias'
    alias.symlink_to(source, target_is_directory=True)
    (root / 'Invalid').mkdir()
    (root / 'Invalid/Metadata.plist').write_text('corrupt metadata')
    original = {str(path): snapshot(path) for path in [source, second]}
    registry.write_bytes(plistlib.dumps({'paths': [], 'opaque': {'retain': True}}))
    env = dict(os.environ, WHISKY_REGISTRY=str(registry), XDG_CONFIG_HOME=str(root / 'config'),
               XDG_DATA_HOME=str(root / 'data'), XDG_STATE_HOME=str(root / 'state'))
    report = {'steps': [], 'passed': False, 'fixture': str(root)}

    def request(method, params=None):
        for attempt in range(40):
            frames = [dict(version=1, id='call', method=method, params=params or {}),
                      dict(version=1, id='stop', method='bridge.shutdown', params={})]
            process = subprocess.run([str(args.helper.resolve())], env=env, text=True, capture_output=True,
                input=''.join(json.dumps(frame) + '\n' for frame in frames), timeout=20, check=True)
            reply = json.loads(process.stdout.splitlines()[0])
            if reply.get('error', {}).get('code') == 'busy':
                time.sleep(0.02)
                continue
            assert reply.get('error') is None, reply
            return reply['result']
        raise AssertionError('Registry stayed busy during concurrent import')

    try:
        request('preferences.set', dict(key='defaultBottleLocation', value=str(root)))
        found = request('workspace.discover')
        assert {item['path'] for item in found} == {str(source), str(second)}, found
        assert plistlib.loads(registry.read_bytes())['paths'] == []
        report['steps'].append('default-root-discovery-skips-corruption-deduplicates-aliases-and-stays-read-only')
        paths = [source, alias, second, source, second, alias]
        with ThreadPoolExecutor(max_workers=6) as pool:
            list(pool.map(lambda path: request('workspace.import', dict(path=str(path))), paths))
        listed = request('workspace.containers')
        assert {entry['path'] for entry in listed} == {str(source), str(second)}, listed
        assert len(plistlib.loads(registry.read_bytes())['paths']) == 2
        assert plistlib.loads(registry.read_bytes())['opaque'] == {'retain': True}
        assert request('workspace.discover') == []
        report['steps'].append('six-independent-helpers-import-once-preserve-opaque-registry-and-reload-after-restart')
        for path in [source, second]:
            assert snapshot(path) == original[str(path)], 'Import changed source files or links'
        report['steps'].append('all-source-file-bytes-and-symlinks-preserved')
        report['passed'] = True
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
