#!/usr/bin/env bash
# Ubuntu 24.04 runtime packages. Run as root; terminal emulators are optional.
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
mapfile -t packages < <(sed -e '/^#/d' -e '/^$/d' "$script_dir/linux-runtime-packages.txt")
apt-get update
apt-get install -y --no-install-recommends "${packages[@]}"
