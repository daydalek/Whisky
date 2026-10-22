"""Isolated interactive-shell probe for real terminal acceptance."""
from pathlib import Path


def install_shell(root):
    script = root / '交互 shell.py'
    script.write_text('''#!/usr/bin/python3
import json
import os
from pathlib import Path
import sys
import time
result = Path(os.environ['WHISKY_TERMINAL_PROBE'])
value = dict(prefix=os.environ.get('WINEPREFIX'), cwd=os.getcwd(), tty=os.isatty(0),
             args=sys.argv[1:], term=os.environ.get('TERM'), pid=os.getpid(), terminalPID=os.getppid())
temporary = Path(str(result) + '.tmp')
temporary.write_text(json.dumps(value))
temporary.replace(result)
print('Whisky terminal acceptance: interactive PTY', flush=True)
print('Prefix: ' + value['prefix'], flush=True)
release = Path(str(result) + '.release')
start = time.monotonic()
while not release.exists() and time.monotonic() - start < 45:
    time.sleep(0.1)
''')
    script.chmod(0o700)
    return script
