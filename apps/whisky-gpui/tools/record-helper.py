#!/usr/bin/env python3
"""Test-only transparent request recorder for a real isolated bridge process."""
import json
import os
import subprocess
import sys
import threading


response_log = os.environ.get('WHISKY_RESPONSE_LOG')
child = subprocess.Popen([os.environ['WHISKY_REAL_HELPER']], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE if response_log else None)
reader = None
if response_log:
    def forward_responses():
        with open(response_log, 'wb') as log:
            for line in child.stdout:
                log.write(line)
                log.flush()
                sys.stdout.buffer.write(line)
                sys.stdout.buffer.flush()
    reader = threading.Thread(target=forward_responses, daemon=True)
    reader.start()
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
    status = child.wait(timeout=15)
    if reader: reader.join(timeout=5)
    sys.exit(status)
finally:
    if child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
