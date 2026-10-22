"""Persist a Linux terminal choice and open it through the production window."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import time


def exercise(window, app, fixture, bottle, registry, snapshot):
    def click(x, y):
        subprocess.run(['xdotool', 'mousemove', '--window', window, str(x), str(y), 'click', '1'], check=True)

    original = {str(p.relative_to(bottle)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in bottle.rglob('*') if p.is_file()}
    original_registry = registry.read_bytes()
    subprocess.run(['xdotool', 'key', '--clearmodifiers', 'ctrl+comma'], check=True)
    time.sleep(1)
    snapshot('linux-terminal-settings')
    click(1090, 210)
    time.sleep(0.4)
    snapshot('linux-terminal-menu')
    click(1100, 294)
    preferences = fixture / 'config/whisky/preferences.plist'
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        assert app.poll() is None, 'Application exited while choosing a terminal'
        if preferences.exists() and plistlib.loads(preferences.read_bytes()).get('preferredLinuxTerminal') == 'xterm':
            break
        time.sleep(0.1)
    else:
        snapshot('linux-terminal-choice-failed')
        raise AssertionError('UI terminal choice did not persist')
    click(1200, 210)
    time.sleep(0.5)
    snapshot('linux-terminal-selected')
    click(90, 145)
    time.sleep(1)
    snapshot('linux-terminal-bottle-before-open')
    click(985, 790)
    probe = fixture / 'probe.json'
    release = Path(str(probe) + '.release')
    try:
        deadline = time.monotonic() + 15
        while not probe.exists() and time.monotonic() < deadline:
            assert app.poll() is None
            time.sleep(0.1)
        if not probe.exists():
            snapshot('linux-terminal-open-failed')
            raise AssertionError('UI terminal action did not start the interactive shell')
        value = json.loads(probe.read_text())
        assert value['prefix'] == str(bottle) and value['cwd'] == str(bottle), value
        assert value['tty'] and value['args'] == ['-i'], value
        terminal = subprocess.check_output(['xdotool', 'search', '--onlyvisible', '--pid', str(value['terminalPID'])], text=True).splitlines()[0]
        subprocess.run(['import', '-window', terminal, str(fixture.parent / 'linux-terminal-opened.png')], check=True)
        current = {str(p.relative_to(bottle)): hashlib.sha256(p.read_bytes()).hexdigest()
                   for p in bottle.rglob('*') if p.is_file()}
        assert current == original and original_registry == registry.read_bytes()
    finally:
        release.touch()
    time.sleep(0.5)
    subprocess.run(['xdotool', 'windowfocus', '--sync', window], check=True)
    snapshot('linux-terminal-return-to-bottle')
