#!/usr/bin/env python3
"""Exercise the production GPUI X11 window and Linux shortcuts under Xvfb."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


def run(*command):
    return subprocess.check_output(command, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--helper', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    fixture = Path(tempfile.mkdtemp(prefix='fixture-', dir=output))
    env = dict(os.environ, WHISKY_BRIDGE_HELPER=str(args.helper.resolve()),
               WHISKY_BRIDGE_NO_WINE='1', WHISKY_GPUI_STATE=str(fixture / 'window.json'),
               WHISKY_REGISTRY=str(fixture / 'BottleVM.plist'),
               XDG_CONFIG_HOME=str(fixture / 'config'), XDG_DATA_HOME=str(fixture / 'data'))
    # Every acceptance run exercises the real helper and isolated empty registry.
    env.pop('WHISKY_GPUI_DEMO_DATA', None)
    report = {'steps': [], 'passed': False}
    app = None
    try:
        with (output / 'application.log').open('w') as log:
            app = subprocess.Popen([str(args.binary.resolve())], env=env,
                                   stdout=log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 45
            window = None
            while time.monotonic() < deadline:
                if app.poll() is not None:
                    raise AssertionError(f'Application exited with {app.returncode}')
                result = subprocess.run(['xdotool', 'search', '--onlyvisible', '--pid', str(app.pid),
                                         '--name', '^Whisky$'], capture_output=True, text=True)
                if result.returncode == 0 and result.stdout.strip():
                    window = result.stdout.splitlines()[0]
                    break
                time.sleep(0.2)
            assert window, 'GPUI window did not become visible'
            run('xdotool', 'windowfocus', '--sync', window)
            time.sleep(3)

            def snapshot(name):
                assert app.poll() is None, 'Application exited before screenshot'
                path = output / f'{name}.png'
                run('import', '-window', window, str(path))
                geometry = run('identify', '-format', '%w %h', str(path)).split()
                assert int(geometry[0]) >= 800 and int(geometry[1]) >= 580, geometry
                report['steps'].append(name)
                return path

            library = snapshot('library')
            run('xdotool', 'key', '--clearmodifiers', 'ctrl+comma')
            time.sleep(1)
            settings = snapshot('settings')
            difference = subprocess.run(['compare', '-metric', 'AE', str(library), str(settings),
                                         'null:'], capture_output=True, text=True)
            assert difference.returncode in (0, 1), difference.stderr
            assert float(difference.stderr.strip().split()[0]) > 2000, \
                'Ctrl+, did not visibly open settings'
            run('xdotool', 'key', '--clearmodifiers', 'ctrl+alt+s')
            time.sleep(1)
            sidebar = snapshot('sidebar-toggled')
            assert sidebar.read_bytes() != settings.read_bytes(), 'Sidebar shortcut had no effect'
            run('xdotool', 'key', '--clearmodifiers', 'ctrl+q')
            assert app.wait(timeout=15) == 0, 'Ctrl+Q exit failed'
            saved = json.loads((fixture / 'window.json').read_text())
            assert saved['width'] >= 800 and saved['height'] >= 580, saved
            report['steps'].append('ctrl-q-and-window-persistence')
            report['passed'] = True
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        if app is not None and app.poll() is None:
            app.terminate()
            try:
                app.wait(timeout=5)
            except subprocess.TimeoutExpired:
                app.kill()
                app.wait()
        (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
