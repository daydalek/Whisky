#!/usr/bin/env bash
# ==============================================================================
# Whisky 32-bit WoW64 Unity Graphics & Crash Prevention E2E Test Runner
# ==============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Ensure python3 is available
if ! command -v python3 &> /dev/null; then
    echo "Error: python3 is required to run the E2E test suite." >&2
    exit 2
fi

# Execute python runner forwarding all CLI arguments
exec python3 "${SCRIPT_DIR}/e2e_runner.py" "$@"
