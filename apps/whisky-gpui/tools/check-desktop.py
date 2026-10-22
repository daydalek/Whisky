#!/usr/bin/env python3
"""Validate and launch generated desktop entries through real GIO in isolated XDG roots."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import runpy
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
    literal = executable.with_name("游戏 %f 'q' $HOME \\ .exe")
    executable.rename(literal)
    executable = literal
    launcher = root / "Frontend = 中文 $HOME 'q' %f \\ literal"
    launcher.write_text('''#!/usr/bin/python3
import json
import os
from pathlib import Path
import sys
output = Path(os.environ['WHISKY_DESKTOP_PROBE'])
output.with_suffix('.tmp').write_text(json.dumps(sys.argv[1:]))
output.with_suffix('.tmp').replace(output)
''')
    launcher.chmod(0o700)
    probe = root / 'delivered.json'
    env = dict(os.environ, WHISKY_REGISTRY=str(registry), WHISKY_DESKTOP_PROBE=str(probe),
               XDG_DATA_HOME=str(root / 'data'), XDG_CONFIG_HOME=str(root / 'config'),
               XDG_DATA_DIRS='/usr/local/share:/usr/share')
    os.environ.update(env)
    from gi.repository import Gio
    applications = root / 'data/applications'
    applications.mkdir(parents=True)
    (applications / 'existing.desktop').write_text('[Desktop Entry]\nType=Application\nName=Existing\nExec=/bin/true\nMimeType=application/x-msi;\n')
    config = root / 'config'
    config.mkdir()
    defaults = config / 'mimeapps.list'
    defaults.write_text('[Default Applications]\napplication/x-msi=existing.desktop;\n')
    defaults_before = defaults.read_bytes()
    before = {str(p.relative_to(bottle)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in bottle.rglob('*') if p.is_file()}
    registry_before = registry.read_bytes()
    bridge_type = runpy.run_path(str(tools / 'check-diagnostics.py'))['Bridge']
    report = {'passed': False, 'steps': [], 'fixture': str(root)}
    with (output / 'helper.log').open('w') as log:
        bridge = bridge_type(args.helper.resolve(), env, log)
        try:
            described = bridge.call('bridge.describe', {})['result']
            assert 'system.desktop' in described['capabilities'] and 'programs.shortcut' in described['capabilities']
            params = dict(launcher=str(launcher))
            assert bridge.call('system.desktop.status', params)['result']['installed'] is False
            installed = bridge.call('system.desktop.install', params)
            assert installed.get('error') is None and installed['result']['cacheUpdated'], installed
            main_entry = Path(installed['result']['path'])
            subprocess.run(['desktop-file-validate', str(main_entry)], check=True)
            assert bridge.call('system.desktop.install', params).get('error') is None
            assert defaults.read_bytes() == defaults_before
            assert Gio.AppInfo.get_default_for_type('application/x-msi', False).get_id() == 'existing.desktop'
            assert any(info.get_id() == main_entry.name for info in Gio.AppInfo.get_all_for_type('application/x-msi'))
            report['steps'].append('validated-application-entry-registers-open-with-and-retains-existing-mime-default')

            def launch(path, files, expected):
                probe.unlink(missing_ok=True)
                app = Gio.DesktopAppInfo.new_from_filename(str(path))
                assert app is not None, path
                assert app.launch([Gio.File.new_for_path(str(file)) for file in files], None)
                deadline = time.monotonic() + 10
                while not probe.exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
                assert json.loads(probe.read_text()) == expected, probe.read_text()

            launch(main_entry, [executable], [str(executable)])
            # Empty %f expansion keeps application-menu launching valid.
            launch(main_entry, [], [])
            shortcut = bridge.call('programs.shortcut.create', dict(params, container=str(bottle),
                executable=str(executable), destination=str(applications), name="游戏 %f 'q'"))
            assert shortcut.get('error') is None, shortcut
            shortcut_path = Path(shortcut['result']['path'])
            subprocess.run(['desktop-file-validate', str(shortcut_path)], check=True)
            launch(shortcut_path, [], ['--open-file', str(executable), '--container', str(bottle)])
            report['steps'].append('real-gio-launch-retains-literal-unicode-quotes-backslashes-percent-and-shell-characters')
            foreign = main_entry.read_bytes()
            main_entry.write_text('[Desktop Entry]\nType=Application\nName=Foreign\nExec=/bin/true\n')
            changed = main_entry.read_bytes()
            assert bridge.call('system.desktop.install', params)['error']['code'] == 'destination_exists'
            assert main_entry.read_bytes() == changed
            main_entry.write_bytes(foreign)
            after = {str(p.relative_to(bottle)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in bottle.rglob('*') if p.is_file()}
            assert before == after and registry.read_bytes() == registry_before
            assert not list(applications.glob('.whisky-desktop-*'))
            report['steps'].append('foreign-entry-prefix-hashes-registry-and-defaults-remain-protected')
            report['passed'] = True
        finally:
            bridge.close()
            (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
