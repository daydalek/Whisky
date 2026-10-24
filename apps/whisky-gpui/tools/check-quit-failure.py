#!/usr/bin/env python3
"""Exercise production quit failure feedback with an isolated real helper behind an error injector."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--binary', required=True, type=Path)
parser.add_argument('--helper', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
fixture = Path(tempfile.mkdtemp(prefix='quit-', dir=output))
proxy = fixture / 'helper.py'
proxy.write_text('''#!/usr/bin/python3
import json,os,subprocess,sys
child=subprocess.Popen([os.environ['WHISKY_REAL_HELPER'],*sys.argv[1:]],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
try:
    for line in sys.stdin:
        request=json.loads(line)
        if request['method']=='bridge.shutdown' and request.get('params',{}).get('applyExitPolicy'):
            open(os.environ['WHISKY_QUIT_ATTEMPT'],'w').write('requested')
            print(json.dumps({'version':1,'id':request['id'],'error':{'code':'operation_failed','message':'Injected Wine termination failure','retryable':True}}),flush=True)
        else:
            child.stdin.write(line); child.stdin.flush()
            print(child.stdout.readline().strip(),flush=True)
finally:
    child.stdin.close()
    try: child.wait(timeout=5)
    except subprocess.TimeoutExpired: child.terminate(); child.wait(timeout=5)
''')
proxy.chmod(0o755)
env = dict(os.environ, WHISKY_REAL_HELPER=str(args.helper.resolve()), WHISKY_BRIDGE_HELPER=str(proxy),
           WHISKY_BRIDGE_NO_WINE='1', WHISKY_QUIT_ATTEMPT=str(fixture / 'attempt'),
           WHISKY_REGISTRY=str(fixture / 'registry.plist'), WHISKY_GPUI_STATE=str(fixture / 'window.json'),
           XDG_CONFIG_HOME=str(fixture / 'config'), XDG_DATA_HOME=str(fixture / 'data'))
env.pop('WHISKY_GPUI_DEMO_DATA', None)
report = {'passed': False}
app = None
try:
    with (output / 'application.log').open('w') as log:
        app = subprocess.Popen([str(args.binary.resolve())], env=env, stdout=log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 40
        window = None
        while time.monotonic() < deadline:
            assert app.poll() is None
            result = subprocess.run(['xdotool', 'search', '--onlyvisible', '--pid', str(app.pid), '--name', '^Whisky$'],
                                    capture_output=True, text=True)
            if result.returncode == 0 and result.stdout.strip():
                window = result.stdout.splitlines()[0]
                break
            time.sleep(0.1)
        assert window
        subprocess.run(['xdotool', 'windowfocus', '--sync', window], check=True)
        time.sleep(2)
        subprocess.run(['xdotool', 'key', '--clearmodifiers', 'ctrl+q'], check=True)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and not (fixture / 'attempt').exists():
            assert app.poll() is None
            time.sleep(0.1)
        assert (fixture / 'attempt').exists(), 'Production quit did not request the exit policy'
        time.sleep(1)
        assert app.poll() is None, 'Failed cleanup closed the application'
        screenshot = output / 'quit-error.png'
        subprocess.run(['import', '-window', window, str(screenshot)], check=True)
        width, height = map(int, subprocess.check_output(['identify', '-format', '%w %h', str(screenshot)], text=True).split())
        subprocess.run(['xdotool', 'mousemove', '--window', window, str(width // 2 + 145),
                        str(height // 2 + 79), 'click', '1'], check=True)
        assert app.wait(timeout=10) == 0, 'Explicit quit did not close the application'
        report = {'passed': True, 'checks': ['production-quit-request', 'error-keeps-window-open',
                                            'explicit-quit-after-error'], 'fixture': str(fixture)}
finally:
    if app is not None and app.poll() is None:
        app.terminate()
        try: app.wait(timeout=5)
        except subprocess.TimeoutExpired: app.kill(); app.wait()
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
