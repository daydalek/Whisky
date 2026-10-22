"""Production Linux diagnostics sheet and save-dialog acceptance."""
import hashlib
from pathlib import Path
import runpy
import subprocess
import time


def exercise(window, app, fixture, bottle, registry, snapshot):
    def click(x, y):
        subprocess.run(['xdotool', 'mousemove', '--window', window, str(x), str(y), 'click', '1'], check=True)
    original = {str(path.relative_to(bottle)): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in bottle.rglob('*') if path.is_file()}
    registry_bytes = registry.read_bytes()
    click(90, 145)
    time.sleep(1)
    click(1220, 790)
    time.sleep(1)
    snapshot('diagnostics-sheet')
    click(640, 255)
    time.sleep(2)
    snapshot('diagnostics-checks')
    click(640, 286)
    time.sleep(2)
    snapshot('diagnostics-report')
    subprocess.run(['xdotool', 'mousemove', '--window', window, '978', '650', 'click', '--repeat', '5', '--delay', '80', '5'], check=True)
    time.sleep(0.5)
    snapshot('diagnostics-export-visible')
    click(640, 653)
    chooser_type = runpy.run_path(str(Path(__file__).with_name('smoke-pickers.py')))['GtkChooser']
    chooser = chooser_type(fixture.parent)
    chooser.window()
    chooser.snapshot('diagnostics-save-picker')
    chooser.wait(chooser.accept, 'Diagnostic report save action is unavailable')
    destination = fixture / 'whisky-diagnostics-Portable Fixture.txt'
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        assert app.poll() is None, 'Application exited during diagnostics export'
        if destination.exists():
            break
        time.sleep(0.1)
    assert destination.exists(), 'Diagnostics UI did not export the selected report'
    report = destination.read_text()
    assert report.startswith('Whisky file diagnostics v1\n')
    assert 'Platform: linux' in report and 'Pinned entries: 1' in report
    assert 'host.container_metadata: pass' in report and 'host.storage:' in report
    assert destination.stat().st_mode & 0o777 == 0o600
    current = {str(path.relative_to(bottle)): hashlib.sha256(path.read_bytes()).hexdigest()
               for path in bottle.rglob('*') if path.is_file()}
    assert current == original and registry.read_bytes() == registry_bytes
    assert not list(fixture.glob('.whisky-diagnostics-*'))
    time.sleep(1)
    snapshot('diagnostics-exported')
    click(974, 89)
    time.sleep(0.5)
