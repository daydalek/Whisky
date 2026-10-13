#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build an ad-hoc signed app ZIP for a fork's GitHub Release.
set -euo pipefail

version="${1:?Usage: build-app-release.sh X.Y.Z}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Version must be X.Y.Z' >&2; exit 2; }
build_number="${BUILD_NUMBER:-1}"
[[ "$build_number" =~ ^[0-9]+$ ]] || { echo 'BUILD_NUMBER must be numeric' >&2; exit 2; }
project="$(cd "$(dirname "$0")/.." && pwd -P)"
output="$project/build/app-release"
assets="$output/assets"
test ! -e "$assets" || { echo 'Release assets directory must be fresh' >&2; exit 1; }
mkdir -p "$output"
cd "$project"

xcodebuild -project Whisky.xcodeproj -scheme Whisky -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$output/DerivedData" \
  build ARCHS=arm64 ONLY_ACTIVE_ARCH=NO MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build_number" CODE_SIGN_IDENTITY='' \
  CC="$(xcrun --find clang)" CXX="$(xcrun --find clang++)" \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO SKIP_SWIFTLINT_BUILD_PHASE=YES \
  > "$output/xcodebuild.log" 2>&1 || { tail -100 "$output/xcodebuild.log"; exit 1; }

app="$output/DerivedData/Build/Products/Release/Whisky.app"
for resource in WhiskyCmd winetricks verbs.txt cabextract; do
  test -f "$app/Contents/Resources/$resource" || { echo "Missing app resource: $resource" >&2; exit 1; }
done
python3 scripts/fill-missing-translations.py --check "$app/Contents/Resources"
mkdir -p "$assets"

python3 - "$app" "$project" "$assets" "$version" <<'PY'
import json, pathlib, plistlib, subprocess, sys
app, project, assets = map(pathlib.Path, sys.argv[1:4])
version = sys.argv[4]
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundleShortVersionString'] == version
assert subprocess.check_output(['lipo', '-archs', str(app / 'Contents/MacOS/Whisky')], text=True).strip() == 'arm64'
# Sign executable leaves, then nested bundles, then the main app.
magics = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf'}
for file in sorted(app.rglob('*')):
    if file.is_file() and not file.is_symlink():
        with file.open('rb') as stream:
            if stream.read(4) in magics:
                subprocess.run(['codesign', '--force', '--sign', '-', str(file)], check=True)
bundles = [p for p in app.rglob('*') if p.is_dir() and not p.is_symlink()
           and p.suffix in ('.app', '.appex', '.framework', '.xpc')]
for bundle in sorted(bundles, key=lambda p: len(p.parts), reverse=True):
    command = ['codesign', '--force', '--sign', '-']
    if bundle.suffix == '.appex':
        command += ['--entitlements', str(project / 'WhiskyThumbnail/WhiskyThumbnail.entitlements')]
    subprocess.run(command + [str(bundle)], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements',
                str(project / 'Whisky/Whisky.entitlements'), str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
record = {'app_version': version, 'architecture': 'arm64',
          'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=project, text=True).strip(),
          'checkout_dirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=project, text=True).strip()),
          'signing': 'ad-hoc', 'notarized': False, 'runtime': 'downloaded separately from the Wine runtime channel'}
(assets / 'build-info.json').write_text(json.dumps(record, indent=2) + '\n')
PY

archive="Whisky-$version-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$assets/$archive"
check_dir="$(mktemp -d "$output/zip-check.XXXXXX")"
ditto -x -k "$assets/$archive" "$check_dir"
codesign --verify --deep --strict "$check_dir/Whisky.app"

cat > "$assets/RELEASE-NOTES.md" <<EOF
Whisky $version for Apple Silicon.

Download $archive, extract Whisky.app and drag it into Applications.
The app downloads CrossOver-based GE Wine Libraries separately on first setup.
The current Wine runtime requires macOS 27+ and Rosetta 2.

This build uses an ad-hoc signature. Apple notarization is pending; macOS Gatekeeper may require additional approval on first launch.
EOF
(cd "$assets" && shasum -a 256 "$archive" build-info.json RELEASE-NOTES.md > SHA256SUMS)
echo "Release assets: $assets"
