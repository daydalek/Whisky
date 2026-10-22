#!/usr/bin/env bash
# Build the production Linux frontend and exercise the real Swift child process.
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
output="${WHISKY_LINUX_OUTPUT:-$repo_root/build/portability/linux-gpui}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
default_cc="$(command -v clang-21 || command -v clang)"
default_cxx="$(command -v clang++-21 || command -v clang-21 || command -v clang++)"
export CC="${CC:-$default_cc}" CXX="${CXX:-$default_cxx}" RUSTC_WRAPPER=
export CARGO_TARGET_DIR="$output/rust-build"
swift --version
rustc --version
python3 "$repo_root/scripts/check-gpui-foundation.py" --output "$output/foundation"
cargo build --locked --jobs "${WHISKY_BUILD_JOBS:-4}" \
    --manifest-path "$repo_root/apps/whisky-gpui/Cargo.toml"
cargo test --locked --jobs "${WHISKY_BUILD_JOBS:-4}" \
    --manifest-path "$repo_root/apps/whisky-gpui/Cargo.toml"
helper="$output/foundation/bridge-build/debug/whisky-bridge"
binary="$CARGO_TARGET_DIR/debug/whisky-gpui"
export WHISKY_BRIDGE_HELPER="$helper" WHISKY_BRIDGE_NO_WINE=1
fixture="$(mktemp -d "$output/cli-XXXXXX")"
# Separate preferences, registry and library from any user installation.
export XDG_CONFIG_HOME="$fixture/config" XDG_DATA_HOME="$fixture/data"
export WHISKY_REGISTRY="$fixture/BottleVM.plist"
"$binary" --print-bridge-status > "$output/bridge-status.json"
"$binary" --print-library --all > "$output/library.json"
python3 - "$output" "$helper" <<'PY'
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
output = Path(sys.argv[1])
status = json.loads((output / 'bridge-status.json').read_text())
assert status['platform'] == 'linux', status
assert 'system.files' in status['capabilities'], status
assert 'runtime.launch' not in status['methods'], status
library = json.loads((output / 'library.json').read_text())
assert library['containers'] == [], library
print('Linux production client/helper handshake and isolated library: passed')

def request(method, params):
    frames = [dict(version=1, id='1', method=method, params=params),
              dict(version=1, id='2', method='bridge.shutdown', params={})]
    result = subprocess.run([sys.argv[2]], input=''.join(json.dumps(frame) + '\n' for frame in frames),
                            text=True, capture_output=True, check=True, timeout=15)
    replies = [json.loads(line) for line in result.stdout.splitlines()]
    assert len(replies) == 2 and all(reply.get('error') is None for reply in replies), replies
    return replies[0]['result']

request('preferences.set', dict(key='librarySort', value='name'))
restarted = request('preferences.read', {})
assert restarted['librarySort'] == 'name', restarted
path = Path(os.environ['XDG_CONFIG_HOME']) / 'whisky/preferences.plist'
assert plistlib.loads(path.read_bytes())['librarySort'] == 'name'
print('Linux XDG preferences survive real helper process restart: passed')
PY
python3 "$repo_root/apps/whisky-gpui/tools/check-programs.py" \
    --helper "$helper" --output "$output/programs"
python3 "$repo_root/apps/whisky-gpui/tools/check-metadata.py" \
    --helper "$helper" --output "$output/metadata"
python3 "$repo_root/apps/whisky-gpui/tools/check-lifecycle.py" \
    --helper "$helper" --output "$output/lifecycle"
python3 "$repo_root/apps/whisky-gpui/tools/check-recovery.py" \
    --helper "$helper" --binary "$binary" --output "$output/recovery"
python3 "$repo_root/apps/whisky-gpui/tools/check-import.py" \
    --helper "$helper" --output "$output/import"
python3 "$repo_root/apps/whisky-gpui/tools/check-export-recovery.py" \
    --helper "$helper" --binary "$binary" --output "$output/export-recovery"

python3 "$repo_root/apps/whisky-gpui/tools/check-diagnostics.py" \
    --helper "$helper" --output "$output/diagnostics"
