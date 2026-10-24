#!/usr/bin/env python3
"""Exercise a production Linux bundle in a native, headless Wayland session."""
import argparse
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

TOOLS = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    bundle = args.bundle.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    assert os.geteuid() != 0, 'Run Wayland acceptance as an ordinary user'
    assert not shutil.which('swift') and not shutil.which('cargo')
    fixture = Path(tempfile.mkdtemp(prefix='fixture-', dir=output))
    generator = runpy.run_path(str(TOOLS / 'check-programs.py'))['fixture_at']
    original, previous_exe, registry, unused_identity = generator(fixture)
    bottle = fixture / "Prefix 包 %f $HOME 'literal'"
    original.rename(bottle)
    executable = bottle / previous_exe.relative_to(original)
    marker = bottle / 'Metadata.plist'
    document = plistlib.loads(marker.read_bytes())
    document['info']['pins'][0]['url'] = {'relative': executable.as_uri()}
    marker.write_bytes(plistlib.dumps(document))
    other = fixture / 'Other Prefix'
    (other / 'drive_c').mkdir(parents=True)
    (other / 'Metadata.plist').write_bytes(plistlib.dumps(dict(info=dict(name='Other Prefix', pins=[], blocklist=[]))))
    registry.write_bytes(plistlib.dumps(dict(paths=[{'relative': other.as_uri()}, {'relative': bottle.as_uri()}])))
    original_registry = plistlib.loads(registry.read_bytes())
    before = {str(p.relative_to(bottle)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in bottle.rglob('*') if p.is_file()}
    key = hashlib.sha256(b'/drive_c/Program Files/Game/game.exe').hexdigest()[:8]
    identity = bottle / f'Program Settings/game-{key}.plist'
    install_shell = runpy.run_path(str(TOOLS / 'terminal-fixture.py'))['install_shell']
    shell = install_shell(fixture)
    session = None
    app = None
    secondary = None
    report = dict(passed=False, steps=[], fixture=str(fixture))

    def wait(predicate, message, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            assert app is None or app.poll() is None, 'Primary application exited during Wayland acceptance'
            try:
                if predicate():
                    return
            except FileNotFoundError:
                pass
            time.sleep(0.1)
        raise AssertionError(message)

    def preferences():
        path = fixture / 'config/whisky/preferences.plist'
        return plistlib.loads(path.read_bytes()) if path.exists() else {}

    try:
        session_type = runpy.run_path(str(TOOLS / 'wayland-driver.py'))['WaylandSession']
        session = session_type(output)
        env = dict(session.env, WHISKY_REGISTRY=str(registry),
                   WHISKY_BRIDGE_HELPER=str(TOOLS / 'record-helper.py'),
                   WHISKY_REAL_HELPER=str(bundle / 'bin/whisky-bridge'),
                   WHISKY_REQUEST_LOG=str(fixture / 'requests.jsonl'),
                   WHISKY_RESPONSE_LOG=str(fixture / 'responses.jsonl'),
                   WHISKY_GPUI_STATE=str(fixture / 'window.json'), WHISKY_BRIDGE_NO_WINE='1',
                   XDG_CONFIG_HOME=str(fixture / 'config'), XDG_DATA_HOME=str(fixture / 'data'),
                   XDG_STATE_HOME=str(fixture / 'state'), SHELL=str(shell),
                   WHISKY_TERMINAL_PROBE=str(fixture / 'probe.json'))
        assert 'DISPLAY' not in env
        report.update(backend='wayland', compositor='sway-headless-pixman', uid=os.geteuid(),
                      waylandDisplay=env['WAYLAND_DISPLAY'])
        with (output / 'application.log').open('w') as log:
            app = subprocess.Popen([str(bundle / 'Whisky')], env=env, stdout=log, stderr=subprocess.STDOUT)
            window = session.wait_window(pid=app.pid)
            assert window['app_id'] == 'com.franke.Whisky' and window['window'] is None, window
            session.focus(window)
            time.sleep(2)
            session.snapshot('wayland-library')
            report['steps'].append('native-xdg-shell-with-stable-desktop-app-id-and-no-x11-display')
            session.key('comma', ('ctrl',))
            time.sleep(0.6)
            session.click(1215, 551)
            wait(lambda: preferences().get('libraryMixedCoverLayout') is False, 'Wayland pointer toggle did not persist')
            session.snapshot('wayland-settings')
            report['steps'].append('native-keyboard-shortcut-and-pointer-preference-write')
            session.click(1200, 295)
            desktop = fixture / 'data/applications/com.franke.Whisky.desktop'
            wait(desktop.exists, 'Wayland desktop installation failed')
            assert desktop.stem == window['app_id']
            report['steps'].append('desktop-entry-identity-matches-native-wayland-app-id')
            selected = fixture / 'Selected 容器目录 %f'
            selected.mkdir()
            session.click(1200, 373)
            chooser_base = runpy.run_path(str(TOOLS / 'smoke-pickers.py'))['GtkChooser']
            class WaylandChooser(chooser_base):
                def window(self):
                    node = session.wait_window(app_id='whisky-file-picker')
                    self.process_id = node['pid']
                    session.focus(node)
                    self.wait(self.application, 'Native GTK Wayland chooser accessibility is unavailable')
                    return node
                def key(self, keys):
                    parts = keys.split('+')
                    session.key(parts[-1], tuple(parts[:-1]))
                def snapshot(self, name):
                    session.snapshot(name)
            chooser = WaylandChooser(output)
            chooser.select_path(selected)
            wait(lambda: preferences().get('defaultBottleLocation') == str(selected), 'Native Wayland chooser result did not persist')
            session.focus(window)
            session.snapshot('wayland-chooser-result')
            report['steps'].append('native-gtk-wayland-directory-chooser-and-literal-unicode-preference')
            session.click(80, 70)
            time.sleep(0.4)
            session.click(300, 150, 'button3')
            time.sleep(0.3)
            session.click(375, 290)
            time.sleep(0.6)
            session.snapshot('wayland-program-settings')
            session.click(500, 415)
            session.key('a', ('ctrl',))
            arguments = "wayland 中文 $HOME 'literal' %f"
            session.text(arguments)
            session.click(968, 770)
            wait(lambda: identity.exists() and plistlib.loads(identity.read_bytes()).get('arguments') == arguments,
                 'Wayland clipboard argument edit did not persist')
            saved = plistlib.loads(identity.read_bytes())
            assert saved['future'] == {'keep': 'opaque'} and saved['environment']['CUSTOM'] == 'retained'
            report['steps'].append('native-wayland-clipboard-unicode-program-save-preserves-unknown-settings')
            session.click(300, 150, 'button3')
            time.sleep(0.3)
            session.click(375, 290)
            time.sleep(0.5)
            session.snapshot('wayland-shortcut-section')
            session.click(725, 770)
            shortcut = fixture / 'data/applications/game.desktop'
            wait(shortcut.exists, 'Wayland shortcut creation failed')
            assert '--container-id' in shortcut.read_text()
            session.click(974, 129)
            child_env = dict(env, WHISKY_GPUI_STATE=str(fixture / 'secondary-window.json'))
            subprocess.run(['gio', 'launch', str(shortcut)], env=child_env, check=True)
            wait(lambda: any(node['pid'] != app.pid and node.get('app_id') == 'com.franke.Whisky'
                             for node in session.windows()), 'GIO did not open a second native Wayland window')
            secondary = next(node for node in session.windows() if node['pid'] != app.pid
                             and node.get('app_id') == 'com.franke.Whisky')
            assert secondary['shell'] == 'xdg_shell' and secondary['window'] is None
            session.focus(secondary)
            time.sleep(2)
            session.snapshot('wayland-shortcut-launched')
            session.key('q', ('ctrl',))
            wait(lambda: all(node['id'] != secondary['id'] for node in session.windows()), 'Secondary Wayland window failed graceful quit')
            secondary = None
            report['steps'].append('real-gio-stable-shortcut-starts-a-second-native-wayland-window')
            session.focus(window)
            session.click(80, 179)
            time.sleep(0.6)
            session.snapshot('wayland-before-terminal')
            session.click(980, 870)
            probe = fixture / 'probe.json'
            wait(probe.exists, 'Native Foot terminal did not start the interactive shell')
            value = json.loads(probe.read_text())
            assert value['tty'] and value['args'] == ['-i'] and value['prefix'] == str(bottle) and value['cwd'] == str(bottle), value
            terminal = session.wait_window(pid=value['terminalPID'])
            assert terminal['app_id'] == 'foot' and terminal['shell'] == 'xdg_shell', terminal
            session.focus(terminal, full=False)
            session.snapshot('wayland-foot-terminal')
            Path(str(probe) + '.release').touch()
            wait(lambda: all(node['id'] != terminal['id'] for node in session.windows()), 'Foot terminal did not close after shell completion')
            report['steps'].append('native-foot-terminal-with-real-interactive-pty-and-literal-prefix')
            session.focus(window)
            session.key('s', ('ctrl', 'alt'))
            time.sleep(0.3)
            session.snapshot('wayland-sidebar-shortcut')
            session.key('q', ('ctrl',))
            assert app.wait(timeout=15) == 0
            saved_window = json.loads((fixture / 'window.json').read_text())
            assert saved_window['width'] >= 800 and saved_window['height'] >= 580, saved_window
            app = None
            for relative, digest in before.items():
                assert hashlib.sha256((bottle / relative).read_bytes()).hexdigest() == digest, relative
            stored_registry = plistlib.loads(registry.read_bytes())
            identities = stored_registry.pop('whiskyContainerIdentities')
            assert stored_registry == original_registry
            assert len(identities) == 1 and next(iter(identities.values()))['path'] == str(bottle)
            report['steps'].append('source-prefix-and-registry-preserved-with-explicit-shortcut-identity-allocation')
            app = subprocess.Popen([str(bundle / 'Whisky')], env=env, stdout=log, stderr=subprocess.STDOUT)
            restored = session.wait_window(pid=app.pid)
            assert restored['app_id'] == 'com.franke.Whisky'
            session.focus(restored)
            time.sleep(1)
            session.snapshot('wayland-restarted')
            assert preferences()['libraryMixedCoverLayout'] is False
            assert plistlib.loads(identity.read_bytes())['arguments'] == arguments
            session.key('q', ('ctrl',))
            assert app.wait(timeout=15) == 0
            app = None
            report['steps'].append('graceful-quit-restart-and-persisted-window-preferences-and-program-data')
        requests = [json.loads(line) for line in (fixture / 'requests.jsonl').read_text().splitlines()]
        methods = {item['method'] for item in requests}
        assert {'system.chooseFolder', 'preferences.set', 'programs.settings.set', 'programs.shortcut.create',
                'system.desktop.install', 'system.desktop.resolve', 'bottle.tools'}.issubset(methods), methods
        assert not methods & {'runtime.configure', 'runtime.launch', 'programs.run', 'audio.test', 'gameConfig.apply'}, methods
        report['recordedMethods'] = sorted(methods)
        report['passed'] = True
    except Exception as error:
        report['error'] = str(error)
        if session and session.process.poll() is None:
            try:
                session.snapshot('wayland-failed')
            except Exception:
                pass
        raise
    finally:
        if session and secondary:
            session.ipc('command', f"[con_id={secondary['id']}] kill")
        if app and app.poll() is None:
            app.terminate()
            try:
                app.wait(timeout=5)
            except subprocess.TimeoutExpired:
                app.kill()
                app.wait()
        if session:
            session.close()
        (output / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
