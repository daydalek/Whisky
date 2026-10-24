"""Native Wayland acceptance driver using headless Sway, persistent virtual input and screencopy."""
import json
import os
from pathlib import Path
import shutil
import select
import struct
import subprocess
import tempfile
import time


class WaylandSession:
    def __init__(self, output):
        self.output = Path(output).resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        self.runtime = Path(tempfile.mkdtemp(prefix='whisky-wayland-', dir='/tmp'))
        self.runtime.chmod(0o700)
        self.env = dict(os.environ, XDG_RUNTIME_DIR=str(self.runtime), WLR_BACKENDS='headless',
                        WLR_RENDERER='pixman', WLR_HEADLESS_OUTPUTS='1', WLR_NO_HARDWARE_CURSORS='1',
                        XDG_SESSION_TYPE='wayland', XDG_CURRENT_DESKTOP='sway',
                        GDK_BACKEND='wayland', GTK_USE_PORTAL='0', GSK_RENDERER='cairo', GTK_A11Y='atspi', WGPU_BACKEND='vulkan')
        for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'SWAYSOCK'):
            self.env.pop(key, None)
        try:
            self.start()
        except BaseException:
            self.close()
            raise

    def start(self):
        config = self.output / 'sway.conf'
        config.write_text('xwayland disable\noutput HEADLESS-1 mode 1280x900\n'
                          'default_border none\ndefault_floating_border none\n'
                          'seat seat0 hide_cursor 0\nfocus_follows_mouse yes\n')
        self.log = (self.output / 'sway.log').open('w')
        self.process = subprocess.Popen(['sway', '-c', str(config)], env=self.env,
                                        stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            assert self.process.poll() is None, 'Sway exited; inspect sway.log'
            sockets = list(self.runtime.glob('sway-ipc.*.sock'))
            displays = [p for p in self.runtime.glob('wayland-*') if not p.name.endswith('.lock')]
            if sockets and displays:
                self.env.update(SWAYSOCK=str(sockets[0]), WAYLAND_DISPLAY=displays[0].name)
                break
            time.sleep(0.1)
        else:
            raise AssertionError('Headless compositor did not publish its sockets')
        self.pointer_log = (self.output / 'pointer.log').open('w')
        self.pointer = subprocess.Popen(['/usr/local/bin/whisky-wayland-input'], env=self.env, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=self.pointer_log, text=True)
        assert select.select([self.pointer.stdout], [], [], 5)[0], 'Virtual pointer setup timed out'
        assert self.pointer.stdout.readline().strip() == 'ready', 'Virtual pointer setup failed'
        self.output_info = self.ipc('get_outputs')
        (self.output / 'outputs.json').write_text(json.dumps(self.output_info, indent=2) + '\n')

    def ipc(self, kind, *arguments):
        command = ['swaymsg', '-r', '-s', self.env['SWAYSOCK']]
        if kind == 'command':
            command += list(arguments)
        else:
            command += ['-t', kind]
        reply = subprocess.check_output(command, env=self.env, text=True, timeout=10)
        value = json.loads(reply)
        if kind == 'command':
            assert all(item['success'] for item in value), value
        return value

    def windows(self):
        result = []
        def walk(node):
            if node.get('pid') and node.get('type') == 'con':
                result.append(node)
            for child in node.get('nodes', []) + node.get('floating_nodes', []):
                walk(child)
        walk(self.ipc('get_tree'))
        return result

    def wait_window(self, pid=None, app_id=None, timeout=25):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for window in self.windows():
                if (pid is None or window['pid'] == pid) and (app_id is None or window.get('app_id') == app_id):
                    assert window.get('shell') == 'xdg_shell', window
                    return window
            time.sleep(0.1)
        raise AssertionError(f'Wayland window not found: pid={pid}, app_id={app_id}')

    def focus(self, window, full=True):
        selector = f"[con_id={window['id']}]"
        self.ipc('command', selector + ' floating enable')
        if full:
            for command in ('border none', 'resize set width 1280 px height 900 px', 'move position 0 0'):
                self.ipc('command', selector + ' ' + command)
        self.ipc('command', selector + ' focus')
        time.sleep(0.2)

    def pointer_command(self, command):
        self.pointer.stdin.write(command + '\n')
        self.pointer.stdin.flush()
        assert select.select([self.pointer.stdout], [], [], 5)[0], 'Virtual pointer request timed out'
        assert self.pointer.stdout.readline().strip() == 'ok', command
        time.sleep(0.05)

    def click(self, x, y, button='button1'):
        number = int(button[-1])
        self.pointer_command(f'move {x} {y}')
        self.pointer_command(f'button {number} 1')
        self.pointer_command(f'button {number} 0')

    def scroll(self, x, y, steps):
        self.pointer_command(f'move {x} {y}')
        self.pointer_command(f'scroll {steps}')

    def key(self, key, modifiers=()):
        keys = dict(q=16, w=17, e=18, r=19, t=20, a=30, s=31, l=38, v=47, comma=51,
                    Return=28, Escape=1, Tab=15, Home=102, End=107, Down=108, Up=103,
                    ctrl=29, shift=42, alt=56, super=125)
        for modifier in modifiers:
            self.pointer_command(f'key {keys[modifier]} 1')
        self.pointer_command(f'key {keys[key]} 1')
        self.pointer_command(f'key {keys[key]} 0')
        for modifier in reversed(modifiers):
            self.pointer_command(f'key {keys[modifier]} 0')

    def text(self, value):
        if hasattr(self, 'clipboard') and self.clipboard.poll() is None:
            self.clipboard.terminate()
            self.clipboard.wait(timeout=3)
        self.clipboard = subprocess.Popen(['wl-copy', '--foreground', '--type', 'text/plain;charset=utf-8'],
                                          env=self.env, stdin=subprocess.PIPE)
        self.clipboard.stdin.write(value.encode())
        self.clipboard.stdin.close()
        time.sleep(0.2)
        self.key('v', ('ctrl',))

    def snapshot(self, name):
        path = self.output / (name + '.png')
        subprocess.run(['grim', '-o', 'HEADLESS-1', str(path)], env=self.env, check=True, timeout=10)
        assert struct.unpack('>II', path.read_bytes()[16:24]) == (1280, 900)
        (self.output / (name + '-tree.json')).write_text(json.dumps(self.ipc('get_tree'), indent=2) + '\n')
        return path

    def close(self):
        for name in ('clipboard', 'pointer', 'process'):
            process = getattr(self, name, None)
            if process and process.poll() is None:
                if name == 'pointer':
                    process.stdin.close()
                else:
                    process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        for name in ('pointer_log', 'log'):
            log = getattr(self, name, None)
            if log:
                log.close()
        shutil.rmtree(self.runtime)
