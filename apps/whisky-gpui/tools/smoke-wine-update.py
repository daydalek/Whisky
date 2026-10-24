#!/usr/bin/env python3
"""Drive Linux Wine install/update and startup checking through the production window."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import runpy
import subprocess
import tempfile
import time

TOOLS = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--helper', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--update-button', default='740,596')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    fixture = Path(tempfile.mkdtemp(prefix='fixture-', dir=output))
    server = runpy.run_path(str(TOOLS / 'check-linux-wine-update.py'))['FixtureServer']()
    server.publish('0.1.6')
    server.delay_archive = True
    preferences = fixture / 'config/whisky/preferences.plist'
    preferences.parent.mkdir(parents=True)
    preferences.write_bytes(plistlib.dumps(dict(checkWhiskyWineUpdates=False)))
    env = {key: value for key, value in os.environ.items() if key not in (
        'WHISKY_BRIDGE_NO_WINE', 'WHISKY_WINE_RUNTIME', 'WHISKY_WINE_FALLBACK_RUNTIME', 'WHISKY_GPUI_DEMO_DATA')}
    env.update(WHISKY_REGISTRY=str(fixture / 'BottleVM.plist'), XDG_CONFIG_HOME=str(fixture / 'config'),
               XDG_DATA_HOME=str(fixture / 'Data 包 %f $HOME'), XDG_STATE_HOME=str(fixture / 'state'),
               WHISKY_GPUI_STATE=str(fixture / 'window.json'), WHISKY_LINUX_WINE_RELEASES_URL=server.endpoint,
               WHISKY_BRIDGE_HELPER=str(TOOLS / 'record-helper.py'), WHISKY_REAL_HELPER=str(args.helper.resolve()),
               WHISKY_REQUEST_LOG=str(fixture / 'requests.jsonl'), WHISKY_RESPONSE_LOG=str(fixture / 'responses.jsonl'))
    root = Path(env['XDG_DATA_HOME']) / 'whisky/runtime/wine'
    app = None
    window = None
    report = dict(passed=False, steps=[], fixture=str(fixture))
    log = (output / 'application.log').open('w')

    def run(*command):
        return subprocess.check_output(command, text=True, timeout=10).strip()

    def wait(predicate, message, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            assert app.poll() is None, 'Application exited during Wine update acceptance'
            try:
                value = predicate()
                if value:
                    return value
            except FileNotFoundError:
                pass
            time.sleep(0.05)
        raise AssertionError(message)

    def records(name):
        path = fixture / (name + '.jsonl')
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text().splitlines(keepends=True) if line.endswith('\n')]

    def connected(count):
        requests = records('requests')
        replies = records('responses')
        return (sum(item['method'] == 'bridge.describe' for item in requests) >= count
                and any('runtime.launch' in item.get('result', {}).get('methods', []) for item in replies))

    def version():
        return json.loads((root / 'current').resolve().parent.joinpath('release.json').read_text())['version']

    def snapshot(name):
        run('import', '-window', window, str(output / (name + '.png')))

    def key(value):
        run('xdotool', 'key', '--clearmodifiers', value)

    def click(x, y):
        run('xdotool', 'mousemove', '--window', window, str(int(x)), str(int(y)), 'click', '1')

    def launch():
        nonlocal app, window
        app = subprocess.Popen([str(args.binary.resolve())], env=env, stdout=log, stderr=subprocess.STDOUT)
        def find_window():
            result = subprocess.run(['xdotool', 'search', '--onlyvisible', '--pid', str(app.pid), '--name', '^Whisky$'],
                                    capture_output=True, text=True, timeout=5)
            return result.stdout.splitlines()[0] if result.returncode == 0 and result.stdout.strip() else None
        window = wait(find_window, 'Production Wine setup window did not appear', timeout=45)
        run('xdotool', 'windowfocus', '--sync', window)
        time.sleep(1)

    def quit_app():
        nonlocal app
        key('ctrl+q')
        assert app.wait(timeout=15) == 0
        app = None

    try:
        launch()
        snapshot('setup-prompt')
        geometry = dict(line.split('=', 1) for line in run('xdotool', 'getwindowgeometry', '--shell', window).splitlines())
        width, height = int(geometry['WIDTH']), int(geometry['HEIGHT'])
        click(width / 2 + 170, height / 2 + 132)
        assert server.archive_started.wait(timeout=15), 'Initial UI action did not download Wine'
        time.sleep(0.5)
        snapshot('setup-downloading')
        server.delay_archive = False
        wait(lambda: version()['patch'] == 6 and connected(2), 'Installed runtime services were not reconnected')
        first = (root / 'current').resolve()
        time.sleep(0.5)
        key('ctrl+comma')
        time.sleep(0.3)
        run('xdotool', 'mousemove', '--window', window, '1100', '650', 'click', '--repeat', '8', '--delay', '60', '5')
        time.sleep(0.4)
        snapshot('setup-installed-settings')
        report['steps'].append('production-first-install-button-download-progress-and-automatic-runtime-service-reconnect')
        server.publish('0.1.7')
        server.delay_archive = True
        server.archive_started.clear()
        x, y = map(int, args.update_button.split(','))
        click(x, y)
        assert server.archive_started.wait(timeout=15), 'Settings update action did not download the next runtime'
        time.sleep(0.3)
        snapshot('setup-update-downloading')
        server.delay_archive = False
        wait(lambda: version()['patch'] == 7 and connected(3), 'Updated runtime services were not reconnected')
        assert first.is_dir() and first != (root / 'current').resolve()
        time.sleep(0.5)
        key('ctrl+comma')
        time.sleep(0.3)
        snapshot('setup-updated-settings')
        report['steps'].append('production-settings-update-switches-generation-and-preserves-previous-runtime')
        quit_app()
        preferences.write_bytes(plistlib.dumps(dict(checkWhiskyWineUpdates=True)))
        server.publish('0.1.8')
        archives_before = sum(path.endswith('/' + 'wine-linux-amd64.tar.gz') for path in server.requests)
        launch()
        def update_detected():
            for item in records('responses'):
                job = item.get('result')
                value = job.get('result') if isinstance(job, dict) else None
                if isinstance(value, dict) and value.get('remoteVersion') == '0.1.8' and value.get('updateAvailable') is True:
                    return True
            return False
        wait(update_detected, 'Automatic startup update check did not find the next Linux release')
        time.sleep(0.3)
        snapshot('setup-automatic-update-notice')
        assert version()['patch'] == 7
        assert sum(path.endswith('/' + 'wine-linux-amd64.tar.gz') for path in server.requests) == archives_before
        quit_app()
        methods = [item['method'] for item in records('requests')]
        assert methods.count('setup.install') == 2 and 'setup.checkUpdate' in methods, methods
        report['steps'].append('restart-persists-runtime-and-enabled-startup-check-detects-the-new-release')
        report['passed'] = True
    except Exception as error:
        report['error'] = str(error)
        if app and app.poll() is None and window:
            snapshot('setup-failure')
        raise
    finally:
        server.delay_archive = False
        if app and app.poll() is None:
            app.terminate()
            try:
                app.wait(timeout=5)
            except subprocess.TimeoutExpired:
                app.kill()
                app.wait()
        server.close()
        log.close()
        (output / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
