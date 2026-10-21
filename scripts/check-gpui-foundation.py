#!/usr/bin/env python3
"""Repeatable isolated compatibility gate for the GPUI migration foundation."""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, default=root / 'build/portability/gpui-foundation')
parser.add_argument('--swift-only', action='store_true')
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
report = {'platform': platform.platform(), 'checks': []}
env = dict(os.environ, RUSTC_WRAPPER='')
env.setdefault('CLANG_MODULE_CACHE_PATH', str(output / 'clang-cache'))


def check(name, command, extra_env=None):
    started = time.monotonic()
    with (output / f'{name}.log').open('w') as log:
        result = subprocess.run(command, cwd=root, env=extra_env or env, stdout=log, stderr=subprocess.STDOUT)
    report['checks'].append({'name': name, 'command': command, 'exitCode': result.returncode,
                             'seconds': round(time.monotonic() - started, 2)})
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    if result.returncode:
        raise SystemExit(f'{name} failed; see {output / (name + ".log")}')
    print(f'{name}: passed', flush=True)


check('core', ['swift', 'test', '--package-path', str(root / 'WhiskyCore'),
               '--scratch-path', str(output / 'core-build')])
with tempfile.TemporaryDirectory(prefix='whisky-gpui-gate-') as temporary:
    bridge = root / 'WhiskyBridge'
    if platform.system() == 'Linux':
        # A platform-specific lock graph is resolved in an isolated copy.
        bridge = Path(temporary) / 'WhiskyBridge'
        shutil.copytree(root / 'WhiskyBridge', bridge, ignore=shutil.ignore_patterns('.build', '.swiftpm', 'Package.resolved'))
        (Path(temporary) / 'WhiskyCore').symlink_to(root / 'WhiskyCore', target_is_directory=True)
    scratch = output / 'bridge-build'
    check('bridge', ['swift', 'test', '--package-path', str(bridge), '--scratch-path', str(scratch)])
    result = subprocess.run(['swift', 'build', '--package-path', str(bridge), '--scratch-path', str(scratch), '--show-bin-path'],
                            env=env, check=True, capture_output=True, text=True)
    helper = Path(result.stdout.strip()) / 'whisky-bridge'
    if not helper.is_file():
        raise SystemExit(f'Missing built helper: {helper}')
    if not args.swift_only:
        check('rust-sdk', ['cargo', 'test', '--locked', '--manifest-path', str(root / 'crates/whisky-bridge/Cargo.toml'),
                           '--target-dir', str(output / 'rust-build'), '--', '--include-ignored'],
              dict(env, WHISKY_BRIDGE_HELPER=str(helper)))
print(output / 'report.json')
