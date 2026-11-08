#!/usr/bin/env python3
"""Repeatable isolated compatibility gate for the GPUI migration foundation."""
import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import time

from bridge_coverage import export_bridge_coverage

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, default=root / 'build/portability/gpui-foundation')
parser.add_argument('--swift-only', action='store_true')
parser.add_argument('--offline', action='store_true',
                    help='Require cached SwiftPM and Cargo dependencies')
parser.add_argument('--coverage', action='store_true',
                    help='Export macOS bridge Swift coverage as bridge.lcov')
args = parser.parse_args()
if args.coverage and platform.system() != 'Darwin':
    parser.error('--coverage currently requires the macOS llvm-cov toolchain')
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
report = {'platform': platform.platform(), 'checks': []}
env = dict(os.environ, RUSTC_WRAPPER='')
if sys.version_info >= (3, 12):
    env.setdefault('WHISKY_TEST_PYTHON', sys.executable)
if platform.system() == 'Linux':
    env.setdefault('CC', shutil.which('clang-21') or 'clang')
    env.setdefault('CXX', shutil.which('clang++-21') or shutil.which('clang-21') or 'clang++')
env.setdefault('CLANG_MODULE_CACHE_PATH', str(output / 'clang-cache'))
swift_build_flags = ['--build-system', 'native'] if platform.system() == 'Linux' else []
swift_resolution_flags = ['--disable-automatic-resolution', '--skip-update'] if args.offline else []
cargo_resolution_flags = ['--offline'] if args.offline else []


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
               '--scratch-path', str(output / 'core-build')] + swift_resolution_flags)
check('metadata', ['swift', 'test', '--package-path', str(root / 'WhiskyMetadata'),
                   '--scratch-path', str(output / 'metadata-build')]
      + swift_build_flags + swift_resolution_flags)
with tempfile.TemporaryDirectory(prefix='whisky-gpui-gate-') as temporary:
    bridge = root / 'WhiskyBridge'
    if platform.system() == 'Linux':
        # A platform-specific lock graph is resolved in an isolated copy.
        bridge = Path(temporary) / 'WhiskyBridge'
        shutil.copytree(root / 'WhiskyBridge', bridge, ignore=shutil.ignore_patterns('.build', '.swiftpm', 'Package.resolved'))
        (Path(temporary) / 'WhiskyCore').symlink_to(root / 'WhiskyCore', target_is_directory=True)
        (Path(temporary) / 'WhiskyMetadata').symlink_to(root / 'WhiskyMetadata', target_is_directory=True)
    scratch = output / 'bridge-build'
    coverage_flags = ['--enable-code-coverage'] if args.coverage else []
    check('bridge', ['swift', 'test', '--package-path', str(bridge), '--scratch-path', str(scratch)]
          + swift_build_flags + swift_resolution_flags + coverage_flags)
    result = subprocess.run(['swift', 'build', '--package-path', str(bridge), '--scratch-path', str(scratch), '--show-bin-path']
                            + swift_build_flags + swift_resolution_flags,
                            env=env, check=True, capture_output=True, text=True)
    helper = Path(result.stdout.strip()) / 'whisky-bridge'
    if not helper.is_file():
        raise SystemExit(f'Missing built helper: {helper}')
    report['helper'] = str(helper.resolve())
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    if args.coverage:
        report.update(export_bridge_coverage(helper.parent, output / 'bridge.lcov', env))
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    if platform.system() == 'Linux':
        for name in ['whisky-file-picker', 'whisky-host-command']:
            tool = helper.with_name(name)
            if not os.access(tool, os.X_OK):
                raise SystemExit(f'Missing built host tool: {tool}')
    if not args.swift_only:
        sdk_env = dict(env, WHISKY_BRIDGE_HELPER=str(helper))
        if args.coverage:
            profiles = output / 'sdk-profiles'
            profiles.mkdir(exist_ok=True)
            sdk_env['LLVM_PROFILE_FILE'] = str(profiles / '%p-%m.profraw')
        check('rust-sdk', ['cargo', 'test', '--locked', '--manifest-path', str(root / 'crates/whisky-bridge/Cargo.toml'),
                           '--target-dir', str(output / 'rust-build')]
              + cargo_resolution_flags + ['--', '--include-ignored'],
              sdk_env)
print(output / 'report.json')
