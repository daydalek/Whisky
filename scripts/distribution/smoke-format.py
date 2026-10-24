#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise an installed deb/rpm or a relocated AppImage with isolated user data."""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time


def window_check(command, env, output, name, title, key, expected):
    with (output / (name + '.log')).open('w') as log:
        process = subprocess.Popen(list(map(str, command)), env=env, stdout=log,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            deadline = time.monotonic() + 90
            window = None
            while time.monotonic() < deadline and process.poll() is None:
                found = subprocess.run(['xdotool', 'search', '--onlyvisible', '--name', title],
                                       env=env, capture_output=True, text=True)
                if found.returncode == 0:
                    window = found.stdout.splitlines()[0]
                    break
                time.sleep(0.5)
            assert window, name + ' window did not appear'
            subprocess.run(['xdotool', 'windowfocus', '--sync', window], env=env, check=True)
            capture = shutil.which('import') or shutil.which('magick')
            assert capture, 'Install ImageMagick for screenshots'
            command = [capture, '-window', window, str(output / (name + '.png'))]
            if Path(capture).name == 'magick':
                command.insert(1, 'import')
            deadline = time.monotonic() + 45
            variation = 0
            while time.monotonic() < deadline and process.poll() is None:
                subprocess.run(command, env=env, check=True, timeout=15)
                convert = shutil.which('convert') or shutil.which('magick')
                variation = float(subprocess.check_output([convert, str(output / (name + '.png')),
                    '-format', '%[fx:standard_deviation]', 'info:'], env=env, text=True))
                if variation > 0.003:
                    break
                time.sleep(0.5)
            assert variation > 0.003, name + ' window has no rendered content'
            subprocess.run(['xdotool', 'key', '--clearmodifiers', key], env=env, check=True)
            process.wait(timeout=30)
            assert process.returncode == expected, (name, process.returncode)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=10)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--format', choices=('deb', 'rpm', 'appimage'), required=True)
    parser.add_argument('--output', type=Path, default=Path('/evidence'))
    args = parser.parse_args()
    output = args.output.resolve()
    if os.geteuid() == 0:
        try:
            subprocess.run(['runuser', '-u', 'whisky-test', '--', 'dbus-run-session', '--', 'python3', __file__, '--format', args.format,
                            '--output', str(output)], check=True)
            if args.format != 'appimage':
                subprocess.run(['dpkg', '--remove', 'whisky'] if args.format == 'deb' else ['rpm', '-e', 'whisky'], check=True)
                assert not Path('/usr/bin/whisky').exists()
                assert not Path('/opt/whisky').exists()
                assert (output / 'home/.local/share/whisky/Bottles/keep-game-data').read_text() == 'preserve\n'
                (output / 'uninstall.json').write_text(json.dumps(dict(passed=True, userDataPreserved=True)) + '\n')
        except Exception as error:
            report_file = output / 'report.json'
            report = json.loads(report_file.read_text()) if report_file.exists() else {}
            report.update(passed=False, error=str(error))
            report_file.write_text(json.dumps(report, indent=2) + '\n')
            raise
        finally:
            if Path('/tmp/xvfb.log').is_file():
                shutil.copyfile('/tmp/xvfb.log', output / 'xvfb.log')
        return
    output.mkdir(exist_ok=True)
    home = output / 'home'
    home.mkdir()
    data = home / '.local/share/whisky/Bottles'
    data.mkdir(parents=True)
    (data / 'keep-game-data').write_text('preserve\n')
    env = dict(os.environ, HOME=str(home), XDG_DATA_HOME=str(home / '.local/share'),
        XDG_CONFIG_HOME=str(home / '.config'), XDG_CACHE_HOME=str(home / '.cache'),
        XDG_STATE_HOME=str(home / '.local/state'), WHISKY_REGISTRY=str(home / 'BottleVM.plist'),
        WHISKY_GPUI_STATE=str(home / 'window.json'), APPIMAGE_EXTRACT_AND_RUN='1',
        GDK_BACKEND='x11', WGPU_BACKEND='vulkan', LIBGL_ALWAYS_SOFTWARE='1')
    assert not shutil.which('swift') and not shutil.which('cargo'), 'Use a clean runtime image'
    launcher = Path('/usr/bin/whisky')
    if args.format == 'appimage':
        directory = output / 'Moved 应用 " $HOME ;'
        directory.mkdir()
        launcher = directory / 'Whisky.AppImage'
        shutil.copyfile('/opt/Whisky.AppImage', launcher)
        launcher.chmod(0o755)
    report = dict(passed=False, format=args.format, launcher=str(launcher), checks=[])
    try:
        for name, command in [('bridge', ['--print-bridge-status']), ('library', ['--print-library', '--all'])]:
            result = subprocess.run([str(launcher)] + command, env=env, capture_output=True, text=True, timeout=120)
            (output / (name + '.log')).write_text(result.stdout + '\n' + result.stderr)
            assert result.returncode == 0, result.stderr
            value = json.loads(result.stdout)
            if name == 'bridge':
                assert value['platform'] == 'linux'
                assert {'setup.status', 'setup.install', 'system.desktop.install'}.issubset(value['methods'])
            else:
                assert value['containers'] == []
            report['checks'].append(name)
        # A second AppImage location verifies fresh extraction and relative helper resolution.
        if args.format == 'appimage':
            moved = output / 'Second location.AppImage'
            launcher.rename(moved)
            launcher = moved
            result = subprocess.run([str(launcher), '--print-bridge-status'], env=env,
                                    capture_output=True, text=True, timeout=120)
            assert result.returncode == 0 and json.loads(result.stdout)['platform'] == 'linux', result.stderr
            report['checks'].append('relocation')
            report['launcher'] = str(launcher)
        window_check([launcher], env, output, 'window', '^Whisky$', 'ctrl+q', 0)
        report['checks'].append('production-window')
        if args.format == 'appimage':
            subprocess.run([str(launcher), '--appimage-extract'], cwd=output, env=env,
                           stdout=subprocess.DEVNULL, check=True, timeout=120)
            appdir = output / 'squashfs-root'
            wrapper = appdir / 'PickerRun'
            script = (appdir / 'AppRun').read_text().replace('bin/whisky-gpui', 'bin/whisky-file-picker')
            bundle = appdir / 'usr/lib/whisky'
        else:
            wrapper = output / 'PickerRun'
            script = Path('/usr/bin/whisky').read_text().replace('bin/whisky-gpui', 'bin/whisky-file-picker')
            script = script.replace('/opt/whisky/Whisky', '/opt/whisky/bin/whisky-file-picker')
            bundle = Path('/opt/whisky')
        wrapper.write_text(script)
        wrapper.chmod(0o755)
        window_check([wrapper, '--file-selection', '--title', 'Whisky packaging chooser',
                      '--filename', home], env, output, 'picker', '^Whisky packaging chooser$', 'Escape', 1)
        report['checks'].append('packaged-gtk-chooser')
        import hashlib
        manifest_file = bundle / ('portable-manifest.json' if args.format in ('rpm', 'appimage') else 'manifest.json')
        manifest = json.loads(manifest_file.read_text())
        for relative, expected in manifest['files'].items():
            with (bundle / relative).open('rb') as stream:
                assert hashlib.file_digest(stream, 'sha256').hexdigest() == expected['sha256'], relative
        report['checks'].append('installed-payload-hashes')
        subprocess.run(['python3', '/tests/check-linux-wine-update.py', '--helper',
                        str(bundle / 'bin/whisky-bridge'), '--output', str(output / 'wine-update')],
                       env=env, check=True, timeout=180)
        report['checks'].append('packaged-wine-download-update-and-cancellation')
        report['passed'] = True
    finally:
        (output / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    main()
