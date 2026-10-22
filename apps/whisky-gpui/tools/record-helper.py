#!/usr/bin/env python3
"""Test-only transparent request recorder for a real isolated bridge process."""
import json
import os
import subprocess
import sys


child = subprocess.Popen([os.environ['WHISKY_REAL_HELPER']], stdin=subprocess.PIPE)
try:
    with open(os.environ['WHISKY_REQUEST_LOG'], 'a') as log:
        for line in sys.stdin:
            log.write(line)
            log.flush()
            child.stdin.write(line.encode())
            child.stdin.flush()
            if json.loads(line)['method'] == 'bridge.shutdown':
                break
    child.stdin.close()
    sys.exit(child.wait(timeout=15))
finally:
    if child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
