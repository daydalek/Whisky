#!/usr/bin/env python3
"""Exercise the production GPUI X11 window and Linux shortcuts under Xvfb."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import runpy
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
    parser.add_argument('--scenario', choices=['empty', 'programs', 'metadata', 'lifecycle'], default='empty')
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
    program_identity = None
    metadata_path = None
    if args.scenario in ('programs', 'metadata', 'lifecycle'):
        generator = runpy.run_path(str(Path(__file__).with_name('check-programs.py')))['fixture_at']
        bottle, executable, registry, identity = generator(fixture)
        env['WHISKY_REGISTRY'] = str(registry)
        if args.scenario == 'programs':
            program_identity = identity
        elif args.scenario == 'metadata':
            params = dict(container=str(bottle), entryID='pinned:' + str(executable))
            cover = fixture / 'cover.png'
            cover.write_bytes(base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAYAAAB/qH1jAAAAEklEQVR4nGP43+HyHxkzoAsAAHyRFlERVA2OAAAAAElFTkSuQmCC'))
            metadata = dict(source='bangumi', sourceID='42', title='Linux Artwork Fixture',
                            originalTitle='', summary='', developer='', releaseDate='', fetchedAt=1000)
            requests = [('metadata.apply', dict(params, metadata=metadata)),
                        ('metadata.cover.import', dict(params, path=str(cover))),
                        ('preferences.set', dict(key='offlineMode', value=True)), ('bridge.shutdown', {})]
            wire = ''.join(json.dumps(dict(version=1, id=str(index), method=method, params=values)) + '\n'
                           for index, (method, values) in enumerate(requests))
            result = subprocess.run([str(args.helper.resolve())], env=env, input=wire, text=True,
                                    capture_output=True, check=True, timeout=20)
            replies = [json.loads(line) for line in result.stdout.splitlines()]
            assert len(replies) == len(requests) and all(reply.get('error') is None for reply in replies), replies
            key = hashlib.sha256(b'program:drive_c/Program Files/Game/game.exe').hexdigest()
            metadata_path = bottle / 'Game Metadata' / (key + '.json')
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
            if args.scenario == 'lifecycle':
                marker = bottle / 'Metadata.plist'
                before = marker.read_bytes()
                run('xdotool', 'mousemove', '--window', window, '90', '145', 'click', '3')
                time.sleep(0.4)
                snapshot('bottle-menu')
                run('xdotool', 'mousemove', '--window', window, '140', '162', 'click', '1')
                time.sleep(0.5)
                snapshot('bottle-rename-dialog')
                run('xdotool', 'mousemove', '--window', window, '600', '390', 'click', '1')
                run('xdotool', 'key', '--clearmodifiers', 'ctrl+a')
                run('xdotool', 'type', '--clearmodifiers', 'Linux UI Renamed')
                run('xdotool', 'mousemove', '--window', window, '810', '505', 'click', '1')
                deadline = time.monotonic() + 12
                while time.monotonic() < deadline:
                    document = plistlib.loads(marker.read_bytes())
                    if document['info']['name'] == 'Linux UI Renamed':
                        break
                    assert app.poll() is None, 'Application exited during container rename'
                    time.sleep(0.1)
                else:
                    raise AssertionError('UI rename did not persist the container name')
                assert document['future'] == {'keep': 'opaque'}, document
                assert marker.read_bytes() != before
                snapshot('bottle-renamed')
                report['steps'].append('production-sidebar-rename-persists-real-metadata')
            if metadata_path is not None:
                assert json.loads(metadata_path.read_text())['title'] == 'Linux Artwork Fixture'
                run('xdotool', 'mousemove', '--window', window, '300', '150', 'click', '3')
                time.sleep(0.5)
                run('xdotool', 'mousemove', '--window', window, '375', '260', 'click', '1')
                time.sleep(1)
                snapshot('metadata-editor')
                cover_settings = Path(str(metadata_path) + '.cover-settings')
                old_cover = json.loads(cover_settings.read_text())['customFileName']
                def cover_setting(key, pending):
                    # Allow in-flight replacement to become visible on shared mounts.
                    # The caller retains its bounded wait and final assertion.
                    try:
                        return json.loads(cover_settings.read_text())[key]
                    except FileNotFoundError:
                        return pending
                run('xdotool', 'mousemove', '--window', window, '375', '504', 'click', '1')
                chooser_type = runpy.run_path(str(Path(__file__).with_name('smoke-pickers.py')))['GtkChooser']
                chooser = chooser_type(output)
                chooser.select_path(cover, delay=6)
                deadline = time.monotonic() + 12
                while time.monotonic() < deadline:
                    if cover_setting('customFileName', old_cover) != old_cover:
                        break
                    assert app.poll() is None, 'Application exited during native cover import'
                    time.sleep(0.1)
                else:
                    raise AssertionError('Native file selection did not import a cover through GPUI')
                report['steps'].append('native-cover-picker-survives-six-seconds-and-imports-through-production-client')
                time.sleep(0.5)
                run('xdotool', 'windowfocus', '--sync', window)
                snapshot('metadata-cover-imported')
                run('xdotool', 'mousemove', '--window', window, '904', '344', 'click', '1')
                deadline = time.monotonic() + 10
                while metadata_path.exists() and time.monotonic() < deadline:
                    assert app.poll() is None, 'Application exited during metadata unlink'
                    time.sleep(0.1)
                assert not metadata_path.exists(), 'UI metadata unlink did not remove the snapshot'
                assert json.loads(cover_settings.read_text())['useCustomCover'] is True
                time.sleep(0.5)
                snapshot('metadata-unlinked')
                run('xdotool', 'mousemove', '--window', window, '490', '482', 'click', '1')
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    if cover_setting('useCustomCover', True) is False:
                        break
                    assert app.poll() is None, 'Application exited during cover reset'
                    time.sleep(0.1)
                else:
                    raise AssertionError('UI cover reset did not update the settings file')
                snapshot('metadata-cover-reset')
                report['steps'].append('metadata-ui-unlink-retains-artwork-and-reset-persists')
                run('xdotool', 'mousemove', '--window', window, '974', '89', 'click', '1')
                time.sleep(0.5)
            if program_identity is not None:
                run('xdotool', 'mousemove', '--window', window, '300', '150', 'click', '3')
                time.sleep(0.5)
                snapshot('program-menu')
                run('xdotool', 'mousemove', '--window', window, '375', '290', 'click', '1')
                time.sleep(1)
                snapshot('program-settings')
                run('xdotool', 'mousemove', '--window', window, '500', '375', 'click', '1')
                run('xdotool', 'key', '--clearmodifiers', 'ctrl+a')
                run('xdotool', 'type', '--clearmodifiers', 'headless-ui-save')
                run('xdotool', 'mousemove', '--window', window, '968', '730', 'click', '1')
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    if program_identity.exists():
                        saved = plistlib.loads(program_identity.read_bytes())
                        if saved.get('arguments') == 'headless-ui-save':
                            break
                    assert app.poll() is None, 'Application exited during program save'
                    time.sleep(0.1)
                else:
                    raise AssertionError('Program argument edit did not reach the identity plist')
                assert saved['future'] == {'keep': 'opaque'}, saved
                assert saved['environment']['CUSTOM'] == 'retained', saved
                report['steps'].append('program-ui-save-retains-native-identity-and-unknown-fields')
                time.sleep(0.5)
                run('xdotool', 'mousemove', '--window', window, '300', '150', 'click', '3')
                time.sleep(0.3)
                run('xdotool', 'mousemove', '--window', window, '375', '290', 'click', '1')
                time.sleep(1)
                snapshot('program-settings-reloaded')
                # Continue the standard desktop checks after dismissing the sheet.
                run('xdotool', 'mousemove', '--window', window, '974', '89', 'click', '1')
                time.sleep(0.5)
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
