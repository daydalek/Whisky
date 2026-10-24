#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$root/scripts/distribution/build.py" "$@"
