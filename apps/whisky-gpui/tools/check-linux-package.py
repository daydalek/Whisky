#!/usr/bin/env python3
"""Verify and relocate a Linux archive in a clean, unprivileged runtime container."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tarfile
import time

PRODUCTS = ('whisky-gpui', 'whisky-bridge', 'whisky-file-picker', 'whisky-host-command')
TOOLS = Path(__file__).resolve().parent


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def verify(bundle):
    manifest = json.loads((bundle / 'manifest.json').read_text())
    assert manifest['formatVersion'] == 1 and manifest['platform'] == 'linux', manifest
    actual = {str(path.relative_to(bundle)) for path in bundle.rglob('*') if path.is_file()}
    assert actual == set(manifest['files']) | {'manifest.json'}, 'Bundle inventory differs from manifest'
    for relative, expected in manifest['files'].items():
        path = bundle / relative
        assert not path.is_symlink() and path.is_relative_to(bundle), relative
        assert digest(path) == expected['sha256'] and path.stat().st_size == expected['bytes'], relative
        assert stat.S_IMODE(path.stat().st_mode) == expected['mode'], relative
    for product in PRODUCTS:
        assert os.access(bundle / 'bin' / product, os.X_OK), product
    assert os.access(bundle / 'Whisky', os.X_OK)
    assert 'libswiftCore.so' in manifest['swiftLibraries']
    assert (bundle / 'bin/WhiskyBridge_WhiskyApplication.resources/linux-wine-archive.py').is_file()
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--gui', action='store_true', help='Run real picker, settings, desktop and terminal window checks')
    parser.add_argument('--wayland', action='store_true', help='Run native headless Wayland window acceptance')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    report = {'passed': False, 'steps': [], 'checks': []}
    started = time.monotonic()
    try:
        assert os.geteuid() != 0, 'Run package acceptance as an unprivileged user'
        assert not shutil.which('swift') and not shutil.which('cargo'), 'Use a runtime image without compilers'
        assert not Path('/usr/lib/swift/linux').exists() and not Path('/usr/local/swift').exists()
        assert not Path('/workspace').exists(), 'Keep the source/build workspace outside the runtime container'
        stage = output / 'unpacked'
        stage.mkdir()
        with tarfile.open(args.archive, 'r:gz') as archive:
            members = archive.getmembers()
            assert all(not p.issym() and not p.islnk() and (p.isdir() or p.isfile())
                       and p.name.split('/')[0] == 'Whisky' and '..' not in Path(p.name).parts for p in members)
            assert sum(p.size for p in members) < 1_000_000_000
            archive.extractall(stage, filter='data')
        bundle = stage / 'Whisky'
        manifest = verify(bundle)
        report.update(architecture=manifest['architecture'], sourceCommit=manifest['sourceCommit'],
                      archiveSha256=digest(args.archive), swiftLibraries=manifest['swiftLibraries'])
        report['steps'].append('unprivileged-clean-runtime-and-complete-manifest-verification')
        home = output / 'home'
        home.mkdir()
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(('WHISKY_', 'LD_', 'DYLD_', 'SWIFT_', 'CARGO_', 'RUST'))}
        env.update(PATH='/usr/bin:/bin', HOME=str(home), XDG_CONFIG_HOME=str(home / '.config'),
                   XDG_DATA_HOME=str(home / '.local/share'), XDG_STATE_HOME=str(home / '.local/state'),
                   WHISKY_REGISTRY=str(home / 'BottleVM.plist'), WHISKY_GPUI_STATE=str(home / 'window.json'))

        def run(name, command):
            before = time.monotonic()
            log = output / (name + '.log')
            with log.open('w') as stream:
                result = subprocess.run([str(arg) for arg in command], env=env, cwd=home,
                                        stdout=subprocess.PIPE, stderr=stream, text=True, timeout=240)
                stream.write(result.stdout)
            report['checks'].append(dict(name=name, exitCode=result.returncode,
                                          seconds=round(time.monotonic() - before, 2)))
            assert result.returncode == 0, f'{name} failed; inspect {log}'
            return result.stdout

        def status(name, executable):
            value = json.loads(run(name, [executable, '--print-bridge-status']))
            assert value['platform'] == 'linux', value
            assert {'system.choosePath', 'system.desktop.install', 'bottle.move', 'gameConfig.match'}.issubset(value['methods']), value
            assert {'setup.status', 'setup.install', 'setup.checkUpdate'}.issubset(value['methods']), value
            assert not any(method.startswith('runtime.') for method in value['methods']), value

        status('initial-launcher', bundle / 'Whisky')
        status('initial-direct-binary', bundle / 'bin/whisky-gpui')
        report['steps'].append('launcher-and-direct-binary-discover-bundled-helper-without-overrides')
        relocated_parent = output / 'Moved 包 " %f $HOME = ;'
        relocated_parent.mkdir()
        relocated = relocated_parent / 'Whisky'
        bundle.rename(relocated)
        assert not bundle.exists()
        alias = output / 'Whisky alias'
        alias.symlink_to(relocated / 'Whisky')
        status('relocated-symlink-launcher', alias)
        status('relocated-direct-binary', relocated / 'bin/whisky-gpui')
        library = json.loads(run('relocated-library', [alias, '--print-library', '--all']))
        assert library['containers'] == [], library
        for product in PRODUCTS:
            links = run('ldd-' + product, ['ldd', relocated / 'bin' / product])
            assert 'not found' not in links, links
            for line in links.splitlines():
                if any(name in line.split()[:1] for name in manifest['swiftLibraries']):
                    resolved = Path(line.split('=>', 1)[1].rsplit(' (', 1)[0].strip()).resolve()
                    assert resolved.parent == (relocated / 'lib/swift').resolve(), line
        report['steps'].append('whole-bundle-relocation-literal-paths-and-local-swift-library-resolution')
        # Exercise the verifier against a changed payload, then restore fixture bytes.
        readme = relocated / 'README.txt'
        original = readme.read_bytes()
        readme.write_bytes(original + b'changed')
        try:
            verify(relocated)
        except AssertionError:
            pass
        else:
            raise AssertionError('Manifest verification accepted a changed payload')
        finally:
            readme.write_bytes(original)
        report['steps'].append('manifest-rejects-a-modified-payload')
        if args.gui:
            prefix = ['xvfb-run', '-a', '-s', '-screen 0 1280x900x24 -nolisten tcp',
                      'dbus-run-session', '--', 'env', 'GTK_A11Y=atspi', 'GDK_BACKEND=x11', 'WGPU_BACKEND=vulkan']
            run('packaged-pickers', prefix + ['python3', TOOLS / 'smoke-pickers.py',
                '--helper', relocated / 'bin/whisky-bridge', '--output', output / 'pickers'])
            for scenario in ('settings', 'desktop', 'terminal', 'gamedb'):
                run('packaged-' + scenario, prefix + ['python3', TOOLS / 'smoke-linux.py',
                    '--binary', relocated / 'Whisky', '--helper', relocated / 'bin/whisky-bridge',
                    '--output', output / (scenario + '-window'), '--scenario', scenario])
                value = json.loads((output / (scenario + '-window') / 'report.json').read_text())
                assert value['passed'], value
            report['steps'].append('packaged-native-pickers-settings-desktop-terminal-and-gamedb-resource-retry')
            run('packaged-wine-update', ['python3', TOOLS / 'check-linux-wine-update.py',
                '--helper', relocated / 'bin/whisky-bridge', '--output', output / 'wine-update'])
            run('packaged-wine-update-window', prefix + ['python3', TOOLS / 'smoke-wine-update.py',
                '--binary', relocated / 'Whisky', '--helper', relocated / 'bin/whisky-bridge',
                '--output', output / 'wine-update-window'])
            report['steps'].append('packaged-wine-download-upgrade-cancellation-and-startup-check-through-cli-and-window')
        if args.wayland:
            run('packaged-wayland', ['dbus-run-session', '--', 'python3', TOOLS / 'smoke-wayland.py',
                '--bundle', relocated, '--output', output / 'wayland-window'])
            value = json.loads((output / 'wayland-window/report.json').read_text())
            assert value['passed'], value
            report['steps'].append('packaged-native-wayland-settings-chooser-clipboard-shortcut-foot-and-restart')
        verify(relocated)
        report['steps'].append('bundle-files-remain-intact-after-runtime-and-window-checks')
        report['passed'] = True
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        report['seconds'] = round(time.monotonic() - started, 2)
        (output / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
