"""Full file lifecycle acceptance through production sidebar and GTK dialogs."""
import hashlib
import os
from pathlib import Path
import plistlib
import runpy
import subprocess
import tarfile
import time
from urllib.parse import unquote, urlparse


def exercise(window, app, fixture, bottle, registry, snapshot):
    def run(*args):
        return subprocess.check_output(args, text=True).strip()

    def click(x, y, button=1):
        run('xdotool', 'mousemove', '--window', window, str(x), str(y), 'click', str(button))

    def wait(predicate, message):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            assert app.poll() is None, 'Application exited: ' + message
            if predicate():
                time.sleep(1)
                return
            time.sleep(0.1)
        snapshot('lifecycle-failure')
        raise AssertionError(message)

    def paths():
        return [Path(unquote(urlparse(value['relative']).path))
                for value in plistlib.loads(registry.read_bytes())['paths']]

    def menu(action, row=0):
        run('xdotool', 'windowfocus', '--sync', window)
        y = 145 + row * 34
        click(90, y, 3)
        time.sleep(0.4)
        click(140, y + {'rename': 17, 'remove': 45, 'move': 82, 'duplicate': 110, 'export': 138}[action])
        time.sleep(0.5)

    chooser_type = runpy.run_path(str(Path(__file__).with_name('smoke-pickers.py')))['GtkChooser']
    outside = fixture / 'External target'
    outside.mkdir()
    (outside / 'keep.txt').write_bytes(b'preserve external data')
    os.symlink(str(outside), bottle / 'external-link')
    payload = bottle / 'drive_c/Program Files/Game/game.exe'
    payload_hash = hashlib.sha256(payload.read_bytes()).hexdigest()
    settings = (bottle / 'Program Settings/game.exe.plist').read_bytes()
    marker = (bottle / 'Metadata.plist').read_bytes()

    # The chooser's prefilled name is also the production export destination.
    archive = fixture / 'Linux UI Renamed.tar'
    menu('export')
    chooser = chooser_type(fixture.parent)
    chooser.window()
    chooser.snapshot('lifecycle-export-picker')
    chooser.wait(chooser.accept, 'Export save action is unavailable')
    wait(archive.exists, 'UI export did not publish an archive')
    wait(lambda: not registry.with_suffix('.plist.export.plist').exists(), 'Export journal persisted')
    with tarfile.open(archive) as exported:
        member = exported.extractfile(bottle.name + '/drive_c/Program Files/Game/game.exe')
        assert hashlib.sha256(member.read()).hexdigest() == payload_hash
        assert exported.getmember(bottle.name + '/external-link').issym()
    assert (bottle / 'Metadata.plist').read_bytes() == marker
    snapshot('bottle-exported')

    # Cancel preserves the original prefix and catalogue.
    menu('move')
    chooser = chooser_type(fixture.parent)
    chooser.window()
    chooser.key('Escape')
    time.sleep(1)
    assert paths() == [bottle] and bottle.exists()
    snapshot('bottle-move-cancelled')

    parent = fixture / 'Moved 中文'
    parent.mkdir()
    menu('move')
    chooser_type(fixture.parent).select_path(parent)
    moved = parent / bottle.name
    wait(lambda: paths() == [moved] and moved.exists() and not bottle.exists(), 'UI move did not persist')
    moved_document = plistlib.loads((moved / 'Metadata.plist').read_bytes())
    assert moved_document['future'] == {'keep': 'opaque'}
    assert moved_document['info']['pins'][0]['url']['relative'] == (moved / payload.relative_to(bottle)).as_uri()
    assert (moved / 'Program Settings/game.exe.plist').read_bytes() == settings
    snapshot('bottle-moved')

    menu('duplicate')
    snapshot('bottle-duplicate-dialog')
    click(600, 390)
    run('xdotool', 'key', '--clearmodifiers', 'ctrl+a')
    run('xdotool', 'type', '--clearmodifiers', 'ZZZ UI Clone')
    click(810, 505)
    wait(lambda: len(paths()) == 2, 'UI duplicate did not register a clone')
    clone = next(path for path in paths() if path != moved)
    document = plistlib.loads((clone / 'Metadata.plist').read_bytes())
    assert document['info']['name'] == 'ZZZ UI Clone'
    assert document['future'] == {'keep': 'opaque'}
    assert document['info']['pins'][0]['url']['relative'] == (clone / payload.relative_to(bottle)).as_uri()
    assert hashlib.sha256((clone / payload.relative_to(bottle)).read_bytes()).hexdigest() == payload_hash
    assert (clone / 'Program Settings/game.exe.plist').read_bytes() == settings
    assert (clone / 'external-link').is_symlink()
    snapshot('bottle-duplicated')

    # Both stable registration order and name order put the clone second.
    menu('remove', row=1)
    snapshot('bottle-deregister-dialog')
    clone_marker = (clone / 'Metadata.plist').read_bytes()
    click(715, 505)
    wait(lambda: paths() == [moved], 'UI deregistration did not update the registry')
    assert (clone / 'Metadata.plist').read_bytes() == clone_marker
    assert (clone / payload.relative_to(bottle)).exists()
    snapshot('bottle-deregistered-files-retained')

    menu('remove')
    snapshot('bottle-delete-dialog')
    click(810, 505)
    wait(lambda: paths() == [] and not moved.exists(), 'UI physical deletion did not complete')
    assert (outside / 'keep.txt').read_bytes() == b'preserve external data'
    assert (clone / payload.relative_to(bottle)).exists()
    assert archive.exists()
    snapshot('bottle-deleted-external-target-retained')
