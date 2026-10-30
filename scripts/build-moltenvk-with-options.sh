#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Build MoltenVK with the optional MVK_CONFIG_EXTERNAL_MEMORY_HOST patch.
# Usage: bash scripts/build-moltenvk-with-options.sh /path/to/new/build-directory
set -euo pipefail

DEST="${1:?provide a new build directory}"
[[ ! -e "$DEST" ]] || { echo "output already exists: $DEST" >&2; exit 1; }
mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd -P)"
REV=db66022459ffb663aa2b50f6b018bc2e124f5edf
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PATCH_FILE="$SCRIPT_DIR/../patches/moltenvk/0001-mvk-config-external-memory-host.patch"

git clone --depth 1 --branch v1.4.2 https://github.com/KhronosGroup/MoltenVK.git "$DEST/src"
[[ "$(git -C "$DEST/src" rev-parse HEAD)" == "$REV" ]] || { echo 'unexpected MoltenVK revision' >&2; exit 1; }

git -C "$DEST/src" apply --check "$PATCH_FILE"
git -C "$DEST/src" apply "$PATCH_FILE"
cd "$DEST/src"
env -u CC -u CXX ./fetchDependencies --macos
env -u CC -u CXX xcodebuild build -project MoltenVKPackaging.xcodeproj \
  -scheme 'MoltenVK Package (macOS only)' -destination 'generic/platform=macOS' \
  -configuration Release ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO -quiet
LIB="$DEST/src/Package/Release/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib"
test -f "$LIB"
strings "$LIB" | grep -Fq MVK_CONFIG_EXTERNAL_MEMORY_HOST
shasum -a 256 "$LIB"
echo "Built successfully: $LIB"
echo "Default: host memory import enabled. Set MVK_CONFIG_EXTERNAL_MEMORY_HOST=0 to disable."
