#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
project="$(cd "$(dirname "$0")/.." && pwd -P)"
work="${1:?Usage: build-cabextract.sh FRESH_WORK_DIRECTORY}"
test ! -e "$work" || { echo 'Build directory must be fresh' >&2; exit 1; }
python3 "$project/scripts/check-third-party.py"
mkdir -p "$work"
tar -xzf "$project/ThirdParty/sources/cabextract-1.11.tar.gz" -C "$work"
cd "$work/cabextract-1.11"
env -u CC -u CXX /bin/sh ./configure --disable-dependency-tracking \
  CC=/usr/bin/clang CFLAGS='-O2 -arch arm64 -mmacosx-version-min=14.0' \
  LDFLAGS='-arch arm64 -mmacosx-version-min=14.0'
make -j4
make check
./cabextract --version
test "$(lipo -archs cabextract)" = arm64
