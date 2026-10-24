"""Exercise desktop installation and program shortcuts through production UI."""
import hashlib
import os
import plistlib
import runpy
from pathlib import Path
import subprocess
import time


def exercise(window, app, fixture, bottle, registry, snapshot, env):
    def click(x, y, button=1):
        subprocess.run(['xdotool', 'mousemove', '--window', window, str(x), str(y), 'click', str(button)], check=True)
    def read_entry(path):
        try:
            return path.read_text()
        except FileNotFoundError:
            return ''
    subprocess.run(['xdotool', 'key', '--clearmodifiers', 'ctrl+comma'], check=True)
    time.sleep(1)
    snapshot('desktop-settings')
    click(1200, 295)
    entry = fixture / 'data/applications/com.franke.Whisky.desktop'
    deadline = time.monotonic() + 15
    frontend = os.readlink(f'/proc/{app.pid}/exe')
    while time.monotonic() < deadline:
        if ("X-Whisky-Launcher=" + frontend + "\n") in read_entry(entry):
            break
        assert app.poll() is None
        time.sleep(0.1)
    assert ('X-Whisky-Launcher=' + frontend + '\n') in entry.read_text(), 'UI desktop update did not refresh the frontend'
    assert all(item in entry.read_text() for item in ('Name=Custom Whisky', 'Icon=custom-icon', 'X-User-Setting=keep'))
    subprocess.run(['desktop-file-validate', str(entry)], check=True)
    time.sleep(1)
    snapshot('desktop-installed')
    click(90, 70)
    time.sleep(0.5)
    click(300, 150, 3)
    time.sleep(0.4)
    click(375, 290)
    time.sleep(1)
    snapshot('desktop-program-settings')
    subprocess.run(['xdotool', 'mousemove', '--window', window, '980', '650', 'click', '--repeat', '70', '--delay', '15', '5'], check=True)
    time.sleep(0.6)
    snapshot('desktop-shortcut-section')
    original_registry = registry.read_bytes()
    marker = (bottle / 'Metadata.plist').read_bytes()
    executable = bottle / 'drive_c/Program Files/Game/game.exe'
    executable_hash = hashlib.sha256(executable.read_bytes()).hexdigest()
    click(370, 647)
    shortcut = fixture / 'data/applications/game.desktop'
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if '--container-id' in read_entry(shortcut):
            break
        assert app.poll() is None
        time.sleep(0.1)
    assert '--container-id' in shortcut.read_text(), 'UI shortcut upgrade did not publish a stable ID'
    assert 'Name=Custom game' in shortcut.read_text()
    subprocess.run(['desktop-file-validate', str(shortcut)], check=True)
    time.sleep(0.7)
    snapshot('desktop-program-shortcut-created')
    shortcut_bytes = shortcut.read_bytes()
    parent = fixture / 'Relocated Prefix'
    parent.mkdir()
    bridge_type = runpy.run_path(str(Path(__file__).with_name('check-diagnostics.py')))['Bridge']
    with (fixture.parent / 'move-helper.log').open('w') as move_log:
        mover = bridge_type(Path(env['WHISKY_REAL_HELPER']), env, move_log)
        try:
            moved = mover.run('bottle.move', dict(container=str(bottle), destination=str(parent)))
            assert moved.get('error') is None, moved
        finally:
            mover.close()
    relocated = parent / bottle.name
    assert relocated.exists() and not bottle.exists()
    assert shortcut.read_bytes() == shortcut_bytes
    child_env = dict(env, WHISKY_GPUI_STATE=str(fixture / 'shortcut-window.json'))
    subprocess.run(['gio', 'launch', str(shortcut)], env=child_env, check=True)
    secondary = None
    try:
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            result = subprocess.run(['xdotool', 'search', '--onlyvisible', '--name', '^Whisky$'],
                                    capture_output=True, text=True)
            candidates = [item for item in result.stdout.splitlines() if item != window]
            if candidates:
                secondary = candidates[0]
                break
            time.sleep(0.1)
        assert secondary, 'GIO shortcut did not open the production application'
        subprocess.run(['xdotool', 'windowfocus', '--sync', secondary], check=True)
        time.sleep(4)
        subprocess.run(['import', '-window', secondary, str(fixture.parent / 'desktop-shortcut-launched.png')], check=True)
        subprocess.run(['xdotool', 'key', '--clearmodifiers', 'ctrl+q'], check=True)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            result = subprocess.run(['xdotool', 'getwindowname', secondary], capture_output=True)
            if result.returncode:
                secondary = None
                break
            time.sleep(0.1)
        assert secondary is None, 'Shortcut-launched application failed graceful exit'
    finally:
        if secondary:
            subprocess.run(['xdotool', 'windowkill', secondary], check=False)
    updated = plistlib.loads(registry.read_bytes())
    records = updated.pop('whiskyContainerIdentities')
    assert len(records) == 1
    assert next(iter(records.values()))['path'] == str(relocated)
    paths = updated.pop('paths')
    before = plistlib.loads(original_registry)
    before.pop('paths')
    updated.pop('whiskyLifecycleCommit')
    assert updated == before
    assert {'relative': relocated.as_uri()} in paths
    metadata = plistlib.loads((relocated / 'Metadata.plist').read_bytes())
    assert metadata['future'] == plistlib.loads(marker)['future']
    assert metadata['info']['pins'][0]['url']['relative'] == (relocated / executable.relative_to(bottle)).as_uri()
    assert hashlib.sha256((relocated / executable.relative_to(bottle)).read_bytes()).hexdigest() == executable_hash
    assert shortcut.read_bytes() == shortcut_bytes
    subprocess.run(['xdotool', 'windowfocus', '--sync', window], check=True)
    click(974, 89)
    time.sleep(0.5)
