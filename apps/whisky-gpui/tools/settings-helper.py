#!/usr/bin/env python3
"""Project optional advertised methods while delegating to the real fixture helper."""
import json
import os
from pathlib import Path
import subprocess
import sys
import threading


child = subprocess.Popen([os.environ['WHISKY_REAL_HELPER']], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
Path(os.environ['WHISKY_SETTINGS_CHILD_PID']).write_text(str(child.pid))
excluded = set(json.loads(Path(os.environ['WHISKY_SETTINGS_EXCLUDED']).read_text()))


def forward_requests():
    try:
        with open(os.environ['WHISKY_REQUEST_LOG'], 'a') as log:
            for line in sys.stdin:
                log.write(line)
                log.flush()
                child.stdin.write(line.encode())
                child.stdin.flush()
    except (BrokenPipeError, ValueError):
        pass
    finally:
        child.stdin.close()


threading.Thread(target=forward_requests, daemon=True).start()
try:
    for line in child.stdout:
        reply = json.loads(line)
        result = reply.get('result')
        if isinstance(result, dict) and 'protocolVersion' in result and 'methods' in result:
            result['methods'] = [method for method in result['methods'] if method not in excluded]
        sys.stdout.write(json.dumps(reply) + '\n')
        sys.stdout.flush()
    sys.exit(child.wait(timeout=10))
finally:
    if child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
