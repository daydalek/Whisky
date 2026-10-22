#!/usr/bin/env bash
# Package dist/Whisky.app from the release builds of whisky-gpui and whisky-bridge.
#
# Layout:
#   dist/Whisky.app/Contents/MacOS/whisky-gpui
#   dist/Whisky.app/Contents/Resources/whisky-bridge
#   dist/Whisky.app/Contents/Resources/AppIcon.icns
#   dist/Whisky.app/Contents/Info.plist
#
# The helper lives at Contents/Resources/whisky-bridge because that is where
# locate_helper() (apps/whisky-gpui/src/bridge/supervisor.rs) looks first,
# relative to the executable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

APP_DIR="${REPO_ROOT}/dist/Whisky.app"
CONTENTS="${APP_DIR}/Contents"
ICONSET_SRC="${REPO_ROOT}/Whisky/Assets.xcassets/AppIcon.appiconset"

# Release builds: Swift helper first, then the GPUI binary.
swift build --package-path "${REPO_ROOT}/WhiskyBridge" -c release
env RUSTC_WRAPPER= cargo build --offline --locked --release \
    --manifest-path "${REPO_ROOT}/apps/whisky-gpui/Cargo.toml"

HELPER_BIN="${REPO_ROOT}/WhiskyBridge/.build/release/whisky-bridge"
GPUI_BIN="${REPO_ROOT}/apps/whisky-gpui/target/release/whisky-gpui"
test -x "${HELPER_BIN}"
test -x "${GPUI_BIN}"

# Assemble the bundle.
rm -rf "${APP_DIR}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"
cp "${GPUI_BIN}" "${CONTENTS}/MacOS/whisky-gpui"
cp "${HELPER_BIN}" "${CONTENTS}/Resources/whisky-bridge"
# Winetricks resolves these beside its executable. They are runtime tools, not
# SwiftPM resources, so the helper build does not carry them.
for resource in cabextract winetricks verbs.txt; do
    cp "${REPO_ROOT}/Libraries/${resource}" "${CONTENTS}/Resources/${resource}"
done
cp "${REPO_ROOT}/Whisky/Resources/WhiskyAudioTest.exe" "${CONTENTS}/Resources/WhiskyAudioTest.exe"
cp -R "${REPO_ROOT}/WhiskyBridge/.build/release/WhiskyKit_WhiskyKit.bundle" \
    "${CONTENTS}/Resources/WhiskyKit_WhiskyKit.bundle"
chmod +x "${CONTENTS}/MacOS/whisky-gpui" "${CONTENTS}/Resources/whisky-bridge" \
    "${CONTENTS}/Resources/cabextract" "${CONTENTS}/Resources/winetricks"

# Version mirrors the SwiftUI app (Whisky.xcodeproj).
VERSION="$(sed -n 's/^[[:space:]]*MARKETING_VERSION = \(.*\);$/\1/p' \
    "${REPO_ROOT}/Whisky.xcodeproj/project.pbxproj" | head -n 1)"
BUILD="$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION = \(.*\);$/\1/p' \
    "${REPO_ROOT}/Whisky.xcodeproj/project.pbxproj" | head -n 1)"
: "${VERSION:?MARKETING_VERSION not found in Whisky.xcodeproj}"
: "${BUILD:=1}"

cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.franke.Whisky.gpui</string>
	<key>CFBundleName</key>
	<string>Whisky</string>
	<key>CFBundleDisplayName</key>
	<string>Whisky</string>
	<key>CFBundleExecutable</key>
	<string>whisky-gpui</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD}</string>
	<key>LSMinimumSystemVersion</key>
	<string>15.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright © Whisky</string>
</dict>
</plist>
PLIST

# Build AppIcon.icns from the SwiftUI appiconset PNGs.
ICONSET_BUILD="$(mktemp -d)/AppIcon.iconset"
mkdir -p "${ICONSET_BUILD}"
cp "${ICONSET_SRC}/16R64x1.png"   "${ICONSET_BUILD}/icon_16x16.png"
cp "${ICONSET_SRC}/16@2x.png"     "${ICONSET_BUILD}/diana.k@example.org"
cp "${ICONSET_SRC}/32R64x1.png"   "${ICONSET_BUILD}/icon_32x32.png"
cp "${ICONSET_SRC}/32@2x.png"     "${ICONSET_BUILD}/adam.d@example.org"
cp "${ICONSET_SRC}/128R128x1.png" "${ICONSET_BUILD}/icon_128x128.png"
cp "${ICONSET_SRC}/128@2x.png"    "${ICONSET_BUILD}/pete.r@example.net"
cp "${ICONSET_SRC}/256R256x1.png" "${ICONSET_BUILD}/icon_256x256.png"
cp "${ICONSET_SRC}/256@2x.png"    "${ICONSET_BUILD}/wendy.h@example.net"
cp "${ICONSET_SRC}/512R512x1.png" "${ICONSET_BUILD}/icon_512x512.png"
cp "${ICONSET_SRC}/512@2x.png"    "${ICONSET_BUILD}/naomi.r@example.net"
iconutil -c icns "${ICONSET_BUILD}" -o "${CONTENTS}/Resources/AppIcon.icns"
rm -rf "$(dirname "${ICONSET_BUILD}")"

# Ad-hoc signing (no entitlements claimed).
codesign -s - "${APP_DIR}"

# Strip a quarantine flag if one is present.
xattr -dr com.apple.quarantine "${APP_DIR}" 2>/dev/null || true

# Smoke check: helper discovery must find the bundled helper (read-only probe).
"${CONTENTS}/MacOS/whisky-gpui" --print-bridge-status

echo "Packaged ${APP_DIR}"
