#!/usr/bin/env python3
"""Drive the real Linux file choosers in an isolated X11/AT-SPI session."""

import argparse
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time

import pyatspi


class GtkChooser:
    def __init__(self, output):
        self.output = Path(output)
        self.process_id = None

    def tree(self, root):
        pending = [root]
        result = []
        while pending and len(result) < 800:
            node = pending.pop()
            try:
                node.clear_cache_single()
                result.append(node)
                pending.extend(reversed(list(node)))
            except Exception:
                continue
        return result

    def application(self):
        desktop = pyatspi.Registry.getDesktop(0)
        for app in desktop:
            try:
                if app.name.lower() == 'whisky-file-picker':
                    if self.process_id is None or app.get_process_id() == self.process_id:
                        return app
            except Exception:
                continue
        return None

    def wait(self, predicate, message, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = predicate()
            if result:
                return result
            time.sleep(0.1)
        app = self.application()
        if app:
            (self.output / 'accessibility.json').write_text(json.dumps([
                {'role': node.getRoleName(), 'name': node.name} for node in self.tree(app)
            ], ensure_ascii=False, indent=2))
        raise AssertionError(message)

    def window(self):
        def visible():
            result = subprocess.run(['xdotool', 'search', '--onlyvisible', '--class', '[Ww]hisky-file-picker'],
                                    capture_output=True, text=True)
            return result.stdout.splitlines()[0] if result.returncode == 0 else None
        window = self.wait(visible, 'Whisky GTK chooser X11 window did not appear')
        self.process_id = int(subprocess.check_output(['xdotool', 'getwindowpid', window], text=True))
        subprocess.run(['xdotool', 'windowfocus', '--sync', window], check=True)
        self.wait(self.application, 'Whisky GTK chooser accessibility tree did not appear')
        return window

    def key(self, keys):
        subprocess.run(['xdotool', 'key', '--clearmodifiers', keys], check=True)

    def snapshot(self, name):
        subprocess.run(['import', '-window', 'root', str(self.output / (name + '.png'))], check=True)

    def enter_path(self, path):
        self.key('ctrl+l')
        def focused_entry():
            app = self.application()
            if app is None:
                return None
            for node in self.tree(app):
                try:
                    if node.getState().contains(pyatspi.STATE_FOCUSED):
                        return node.queryEditableText()
                except Exception:
                    continue
            return None
        entry = self.wait(focused_entry, 'Focused file-location entry is unavailable')
        assert entry.setTextContents(str(path))
        self.key('Return')

    def accept(self):
        app = self.application()
        if app is None:
            return
        for node in self.tree(app):
            try:
                if node.getRoleName() == 'push button' and node.name in ('Open', 'Select', 'Save', 'OK'):
                    if node.getState().contains(pyatspi.STATE_SENSITIVE):
                        assert node.queryAction().doAction(0)
                        return True
            except Exception:
                continue

    def select_all(self, names):
        def select():
            app = self.application()
            if app is None:
                return False
            for node in self.tree(app):
                try:
                    selection = node.querySelection()
                    labels = {child.name for child in self.tree(node)}
                    if set(names).issubset(labels) and selection.selectAll():
                        return True
                except Exception:
                    continue
            return False
        self.wait(select, 'Multi-directory selection is unavailable')

    def select_path(self, path, delay=0):
        self.window()
        if delay:
            time.sleep(delay)
        self.enter_path(path)
        time.sleep(0.5)
        self.accept()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    fixture = Path(tempfile.mkdtemp(prefix='fixture-', dir=output))
    file = fixture / "中文 $HOME 'literal' |.png"
    file.write_text('selection fixture')
    folder = fixture / 'Selected Folder'
    folder.mkdir()
    env = dict(os.environ, LC_ALL='C.UTF-8', GTK_A11Y='atspi', GDK_BACKEND='x11',
               WHISKY_REGISTRY=str(fixture / 'BottleVM.plist'),
               XDG_CONFIG_HOME=str(fixture / 'config'), XDG_DATA_HOME=str(fixture / 'data'))
    log = (output / 'helper.log').open('w')
    helper = subprocess.Popen([str(args.helper.resolve())], env=env, text=True,
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)
    chooser = GtkChooser(output)
    sequence = 0
    report = {'steps': [], 'passed': False}

    def begin(method, params=None):
        nonlocal sequence
        sequence += 1
        helper.stdin.write(json.dumps(dict(version=1, id=str(sequence), method=method, params=params or {})) + '\n')
        helper.stdin.flush()

    def reply():
        assert select.select([helper.stdout], [], [], 20)[0], 'Chooser reply timed out'
        value = json.loads(helper.stdout.readline())
        assert value['id'] == str(sequence) and value.get('error') is None, value
        time.sleep(0.2)
        return value['result']

    try:
        begin('system.choosePath', dict(mode='file', purpose='cover-import', path=str(fixture), extensions=['png']))
        chooser.window()
        chooser.snapshot('open-file')
        chooser.select_path(file, delay=6)
        selected = reply()
        assert selected['path'] == str(file) and selected['purpose'] == 'cover-import', selected
        report['steps'].append('real-file-picker-literal-unicode-path-and-six-second-interaction')

        begin('system.chooseFolder', dict(path=str(fixture)))
        chooser.select_path(folder)
        selected = reply()
        assert selected['path'] == str(folder), selected
        report['steps'].append('real-directory-picker')

        begin('system.chooseFolder', dict(path=str(fixture / 'Fresh/Whisky/Bottles')))
        chooser.select_path(folder)
        selected = reply()
        assert selected['path'] == str(folder), selected
        assert not (fixture / 'Fresh').exists()
        report['steps'].append('missing-initial-directory-opens-existing-ancestor-without-creating-paths')

        destination = fixture / '保存 Report.tar'
        begin('system.choosePath', dict(mode='save', purpose='export', path=str(fixture), name=destination.name, extensions=['tar']))
        chooser.window()
        time.sleep(0.3)
        chooser.snapshot('save-file')
        chooser.wait(chooser.accept, 'Save action was unavailable')
        selected = reply()
        assert selected['path'] == str(destination) and selected['purpose'] == 'export', selected
        assert not destination.exists(), 'Selecting a destination created the archive'
        report['steps'].append('real-save-picker-prefills-the-name-and-returns-an-unwritten-destination')

        multi = fixture / 'Multi'
        multi.mkdir()
        for name in ['First', 'Second']:
            (multi / name).mkdir()
        begin('system.chooseFolders', dict(path=str(multi)))
        chooser.window()
        chooser.select_all(['First', 'Second'])
        chooser.snapshot('multi-directory')
        chooser.accept()
        selected = reply()
        assert set(selected['paths']) == {str(multi / name) for name in ['First', 'Second']}, selected
        report['steps'].append('real-multi-directory-picker')

        begin('system.choosePath', dict(mode='file', path=str(fixture)))
        chooser.window()
        chooser.key('Escape')
        assert reply()['path'] is None
        begin('bridge.describe')
        assert 'system.chooseFolders' in reply()['methods']
        report['steps'].append('cancel-keeps-the-bridge-session-usable')
        timeout_result = subprocess.run([
            str(args.helper.resolve().with_name('whisky-file-picker')),
            '--file-selection', '--timeout=1', '--title=Whisky timeout fixture',
        ], env=env, capture_output=True, timeout=15)
        assert timeout_result.returncode == 5, timeout_result
        report['steps'].append('native-dialog-deadline-returns-timeout')

        begin('system.chooseFolder', dict(path=str(fixture)))
        chooser.window()
        picker_pid = chooser.process_id
        helper.terminate()
        assert helper.wait(timeout=10) < 0
        def picker_stopped():
            status = Path(f'/proc/{picker_pid}/stat')
            try:
                return status.read_text().rsplit(')', 1)[1].split()[0] == 'Z'
            except FileNotFoundError:
                return True
        chooser.wait(picker_stopped, 'Native chooser survived its bridge parent')
        report['steps'].append('native-dialog-exits-with-its-bridge-parent')
        report['passed'] = True
    except Exception as error:
        report['error'] = str(error)
        chooser.snapshot('failure')
        raise
    finally:
        if helper.poll() is None:
            helper.terminate()
            try:
                helper.wait(timeout=5)
            except subprocess.TimeoutExpired:
                helper.kill()
                helper.wait()
        log.close()
        (output / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    main()
