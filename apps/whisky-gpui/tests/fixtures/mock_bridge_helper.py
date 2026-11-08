#!/usr/bin/env python3
"""Deterministic whisky-bridge fixture for the CLI integration tests.

Speaks the NDJSON request/response protocol on stdin/stdout. Library entries
come from MOCK_BRIDGE_ENTRIES (a JSON file path) so the tests reuse the
checked-in library fixture verbatim.
"""

import json
import os
import sys

METHODS = [
    "bridge.describe",
    "bridge.shutdown",
    "workspace.recover",
    "workspace.containers",
    "library.entries",
]

CONTAINERS = [
    {
        "name": "Fixture Bottle",
        "path": "/virtual/fixture-bottle",
        "available": True,
    }
]


def entries():
    path = os.environ.get("MOCK_BRIDGE_ENTRIES")
    if not path:
        return []
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            continue
        method = request.get("method", "")
        if method == "bridge.describe":
            result = {
                "protocolVersion": 1,
                "platform": "fixture",
                "methods": METHODS,
                "capabilities": ["fixture"],
                "maximumFrameBytes": 1048576,
                "registry": "/virtual/registry",
                "dateUnit": "unix_seconds",
                "pathFormat": "absolute_native",
            }
        elif method == "workspace.containers":
            result = CONTAINERS
        elif method == "library.entries":
            result = entries()
        else:
            result = {}
        sys.stdout.write(
            json.dumps({"version": 1, "id": request.get("id"), "result": result}) + "\n"
        )
        sys.stdout.flush()


if __name__ == "__main__":
    main()
