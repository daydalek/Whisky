#!/usr/bin/env bash
# Build a Linux release in isolated SwiftPM scratch storage and package it.
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
output="${WHISKY_LINUX_RELEASE_OUTPUT:-$repo_root/build/portability/linux-release}"
mkdir -p "$output"
output="$(cd -- "$output" && pwd)"
cache="${WHISKY_LINUX_BUILD_CACHE:-$output}"
mkdir -p "$cache"
cache="$(cd -- "$cache" && pwd)"
export CC="${CC:-$(command -v clang-21 || command -v clang)}"
export CXX="${CXX:-$(command -v clang++-21 || command -v clang++)}"
export RUSTC_WRAPPER=
# Linux and macOS have distinct lock graphs; keep the checkout read-only.
python3 - "$repo_root" "$output" "$cache" <<'PY'
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
root, output, cache = map(Path, sys.argv[1:])
with tempfile.TemporaryDirectory(prefix='whisky-linux-release-') as folder:
    workspace = Path(folder)
    bridge = workspace / 'WhiskyBridge'
    shutil.copytree(root / 'WhiskyBridge', bridge,
                    ignore=shutil.ignore_patterns('.build', '.swiftpm', 'Package.resolved'))
    for name in ('WhiskyCore', 'WhiskyMetadata'):
        (workspace / name).symlink_to(root / name, target_is_directory=True)
    command = ['swift', 'build', '--jobs', os.environ.get('WHISKY_BUILD_JOBS', '4'),
               '--package-path', str(bridge), '--scratch-path', str(cache / 'bridge-build'),
               '--build-system', 'native', '-c', 'release']
    subprocess.run(command, check=True)
    products = subprocess.check_output(command + ['--show-bin-path'], text=True).strip()
    (output / 'products-path.txt').write_text(products + '\n')
PY
cargo build --locked --release --jobs "${WHISKY_BUILD_JOBS:-4}" \
    --manifest-path "$repo_root/apps/whisky-gpui/Cargo.toml" --target-dir "$cache/rust-build"
python3 "$repo_root/apps/whisky-gpui/tools/package-linux.py" \
    --frontend "$cache/rust-build/release/whisky-gpui" \
    --products "$(cat "$output/products-path.txt")" --output "$output/Whisky" \
    --archive "$output/whisky-linux-$(uname -m).tar.gz"
