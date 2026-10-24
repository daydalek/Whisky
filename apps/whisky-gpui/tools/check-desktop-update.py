#!/usr/bin/env python3
"""Refresh old desktop launchers through the real helper and recover an observed SIGKILL."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import plistlib
import runpy
import signal
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix='fixture-', dir=output))
    tools = Path(__file__).parent
    bottle, executable, registry, identity = runpy.run_path(str(tools / 'check-programs.py'))['fixture_at'](root)
    legacy = runpy.run_path(str(tools / 'desktop-fixture.py'))['contents']
    probe = root / 'delivered.json'
    launchers = [root / "Old frontend = 'q' 中文", root / "New frontend = $HOME %f 中文"]
    code = '''#!/usr/bin/python3
import json
import os
from pathlib import Path
import sys
result = Path(os.environ['WHISKY_DESKTOP_PROBE'])
result.with_suffix('.tmp').write_text(json.dumps(dict(launcher=sys.argv[0], arguments=sys.argv[1:])))
result.with_suffix('.tmp').replace(result)
'''
    for launcher in launchers:
        launcher.write_text(code)
        launcher.chmod(0o700)
    env = dict(os.environ, WHISKY_REGISTRY=str(registry), WHISKY_DESKTOP_PROBE=str(probe),
               XDG_DATA_HOME=str(root / 'data'), XDG_CONFIG_HOME=str(root / 'config'))
    os.environ.update(env)
    from gi.repository import Gio
    bridge_type = runpy.run_path(str(tools / 'check-diagnostics.py'))['Bridge']
    applications = root / 'data/applications'
    applications.mkdir(parents=True)
    (applications / 'existing.desktop').write_text('[Desktop Entry]\nType=Application\nName=Existing\nExec=/bin/true\nMimeType=application/x-msi;\n')
    app_entry = applications / 'com.franke.Whisky.desktop'
    app_entry.write_text(legacy('Custom Whisky', launchers[0], files=True).replace('Icon=applications-games', 'Icon=custom-icon') +
                         '# retained comment\nX-User-Setting=opaque\nActions=Custom;\n[Desktop Action Custom]\nName=Custom\nExec=/bin/true\n')
    app_entry.chmod(0o640)
    shortcut = applications / 'game.desktop'
    shortcut.write_text(legacy('Custom game', launchers[0], ['--open-file', executable, '--container', bottle]))
    config = root / 'config'
    config.mkdir()
    defaults = config / 'mimeapps.list'
    defaults.write_text('[Default Applications]\napplication/x-msi=existing.desktop;\n')
    original_defaults = defaults.read_bytes()
    report = {'passed': False, 'steps': [], 'fixture': str(root)}
    with (output / 'helper.log').open('w') as log:
        bridge = bridge_type(args.helper.resolve(), env, log)
        try:
            params = dict(launcher=str(launchers[1]))
            assert bridge.call('system.desktop.status', params)['result']['needsUpdate']
            launchers[0].unlink()
            installed = bridge.call('system.desktop.install', params)
            assert installed.get('error') is None and installed['result']['updated'], installed
            text = app_entry.read_text()
            assert all(item in text for item in ('Name=Custom Whisky', 'Icon=custom-icon', 'X-User-Setting=opaque', '[Desktop Action Custom]'))
            assert app_entry.stat().st_mode & 0o777 == 0o640
            assert bridge.call('system.desktop.status', params)['result']['installed']
            created = bridge.call('programs.shortcut.create', dict(params, container=str(bottle),
                executable=str(executable), destination=str(applications)))
            assert created.get('error') is None and created['result']['updated'], created
            assert 'Name=Custom game' in shortcut.read_text() and '--container-id' in shortcut.read_text()
            for entry, arguments in [(app_entry, []), (shortcut, ['--open-file', created['result']['programPath'],
                                                                  '--container-id', created['result']['containerID']])]:
                subprocess.run(['desktop-file-validate', str(entry)], check=True)
                probe.unlink(missing_ok=True)
                assert Gio.DesktopAppInfo.new_from_filename(str(entry)).launch([], None)
                deadline = time.monotonic() + 10
                while not probe.exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
                delivered = json.loads(probe.read_text())
                assert delivered == dict(launcher=str(launchers[1]), arguments=arguments), delivered
            assert defaults.read_bytes() == original_defaults
            assert Gio.AppInfo.get_default_for_type('application/x-msi', False).get_id() == 'existing.desktop'
            report['steps'].append('removed-old-frontend-is-replaced-while-custom-fields-permissions-and-mime-defaults-survive')
            report['steps'].append('legacy-path-shortcut-upgrades-to-stable-id-and-real-gio-launches-the-new-frontend')
            # Alternate two real executable paths and stop only an observed live transaction.
            launchers[0].write_text(code)
            launchers[0].chmod(0o700)
            journal_path = Path(str(app_entry) + '.whisky-update.plist')
            caught = None
            for attempt in range(24):
                desired = launchers[attempt % 2]
                params = dict(launcher=str(desired))
                with ThreadPoolExecutor(max_workers=1) as pool:
                    call = pool.submit(bridge.call, 'system.desktop.install', params)
                    deadline = time.monotonic() + 8
                    while not call.done() and time.monotonic() < deadline:
                        if journal_path.exists():
                            os.kill(bridge.process.pid, signal.SIGSTOP)
                            stop_deadline = time.monotonic() + 2
                            while time.monotonic() < stop_deadline:
                                if '\nState:\tT' in Path(f'/proc/{bridge.process.pid}/status').read_text(errors='replace'):
                                    break
                                time.sleep(0.001)
                            if journal_path.exists():
                                caught = plistlib.loads(journal_path.read_bytes())
                                current = app_entry.stat() if app_entry.exists() else None
                                committed = current is not None and current.st_ino == caught['newIdentity']['inode'] and current.st_dev == caught['newIdentity']['device']
                                os.kill(bridge.process.pid, signal.SIGKILL)
                                assert bridge.process.wait(timeout=10) == -signal.SIGKILL
                                try:
                                    call.result(timeout=10)
                                except Exception:
                                    pass
                                (output / 'observed-update.plist').write_bytes(plistlib.dumps(caught))
                                break
                            os.kill(bridge.process.pid, signal.SIGCONT)
                        time.sleep(0.0005)
                    if caught:
                        break
                    reply = call.result(timeout=15)
                    assert reply.get('error') is None, reply
            assert caught is not None, 'No live desktop update transaction was observed'
            bridge = bridge_type(args.helper.resolve(), env, log)
            response = bridge.call('system.desktop.status', params)
            assert response.get('error') is None, response
            assert app_entry.read_bytes() == caught['newData' if committed else 'oldData']
            assert not journal_path.exists()
            assert not list(applications.glob('.whisky-desktop-*'))
            assert bridge.call('system.desktop.install', params).get('error') is None
            assert defaults.read_bytes() == original_defaults
            report['steps'].append('observed-live-update-sigkill-and-fresh-helper-status-recovery-preserve-a-complete-entry')
            report['observedCommitted'] = committed
            report['passed'] = True
        finally:
            if bridge.process.poll() is None:
                bridge.close()
            (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
