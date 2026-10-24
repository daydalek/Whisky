#!/usr/bin/env python3
"""Run a real Linux terminal and PTY through the production helper under Xvfb."""
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
    generate = runpy.run_path(str(tools / 'check-programs.py'))['fixture_at']
    bottle, executable, registry, identity = generate(root)
    literal = root / "中文 $HOME 'literal' $(touch INJECTION_SENTINEL)"
    bottle.rename(literal)
    bottle = literal
    registry.write_bytes(plistlib.dumps({'paths': [{'relative': bottle.as_uri()}]}))
    before = {str(p.relative_to(bottle)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in bottle.rglob('*') if p.is_file()}
    registry_bytes = registry.read_bytes()
    probe = root / 'probe.json'
    shell = runpy.run_path(str(tools / 'terminal-fixture.py'))['install_shell'](root)
    env = dict(os.environ, SHELL=str(shell), WHISKY_TERMINAL_PROBE=str(probe),
               WHISKY_REGISTRY=str(registry), XDG_CONFIG_HOME=str(root / 'config'),
               XDG_DATA_HOME=str(root / 'data'))
    bridge_type = runpy.run_path(str(tools / 'check-diagnostics.py'))['Bridge']
    report = {'passed': False, 'steps': [], 'fixture': str(root)}
    closed = False
    window = None
    with (output / 'helper.log').open('w') as log:
        bridge = bridge_type(args.helper.resolve(), env, log)
        try:
            describe = bridge.call('bridge.describe', {})['result']
            assert 'system.terminal' in describe['capabilities']
            discovered = bridge.call('system.terminals', {})['result']
            assert discovered['displayAvailable'] and any(t['id'] == 'xterm' for t in discovered['available'])
            for preferred in ('xterm', 'auto'):
                probe.unlink(missing_ok=True)
                release = Path(str(probe) + '.release')
                release.unlink(missing_ok=True)
                bridge.call('preferences.set', dict(key='preferredLinuxTerminal', value=preferred))
                opened = bridge.call('bottle.tools', dict(container=str(bottle), tool='terminal'))
                assert opened.get('error') is None, opened
                deadline = time.monotonic() + 15
                while not probe.exists() and time.monotonic() < deadline:
                    time.sleep(0.1)
                result = json.loads(probe.read_text())
                assert result['prefix'] == str(bottle) and result['cwd'] == str(bottle), result
                assert result['tty'] and result['args'] == ['-i'], result
                visible = subprocess.check_output(['xdotool', 'search', '--onlyvisible', '--pid', str(result['terminalPID'])], text=True)
                window = visible.splitlines()[0]
                subprocess.run(['import', '-window', window, str(output / (preferred + '-terminal.png'))], check=True)
                assert bridge.call('workspace.containers', {}).get('error') is None
                if preferred == 'auto':
                    bridge.close()
                    closed = True
                    os.kill(result['pid'], 0)
                release.touch()
                time.sleep(0.7)
                window = None
                report['steps'].append(preferred + '-opens-real-terminal-with-literal-cwd-prefix-and-interactive-pty')
            headless = dict(env)
            headless.pop('DISPLAY', None)
            headless.pop('WAYLAND_DISPLAY', None)
            other = bridge_type(args.helper.resolve(), headless, log)
            try:
                status = other.call('system.terminals', {})['result']
                assert not status['displayAvailable'] and status['available']
                failure = other.call('bottle.tools', dict(container=str(bottle), tool='terminal'))
                assert failure['error']['code'] == 'display_unavailable', failure
            finally:
                other.close()
            after = {str(p.relative_to(bottle)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in bottle.rglob('*') if p.is_file()}
            assert before == after and registry.read_bytes() == registry_bytes
            assert not list(root.rglob('INJECTION_SENTINEL'))
            report['steps'] += ['bridge-remains-responsive-and-terminal-survives-helper-shutdown',
                                'headless-discovery-and-display-error-are-explicit',
                                'prefix-and-registry-bytes-preserved-with-zero-path-injection']
            report['passed'] = True
        finally:
            Path(str(probe) + '.release').touch()
            if window:
                subprocess.run(['xdotool', 'windowkill', window], check=False)
            if not closed:
                bridge.close()
            (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
