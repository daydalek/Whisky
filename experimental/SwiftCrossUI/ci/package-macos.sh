#!/bin/bash
set -euo pipefail
prototype_dir="$(cd "$(dirname "$0")/.." && pwd)"
workspace_dir="$(cd "$prototype_dir/../.." && pwd)"
swift build --package-path "$prototype_dir" --force-resolved-versions --product WhiskyCrossUI
binary_dir="$(swift build --package-path "$prototype_dir" --show-bin-path)"
destination="$workspace_dir/build/portability/${WHISKY_CROSSUI_APP_NAME:-WhiskyCrossUI}.app"
staging_dir="$(mktemp -d "$workspace_dir/build/portability/.crossui-package.XXXXXX")"
app_dir="$staging_dir/WhiskyCrossUI.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/WhiskyCrossUI" "$app_dir/Contents/MacOS/WhiskyCrossUI"
cp -R "$binary_dir/WhiskyKit_WhiskyKit.bundle" "$app_dir/Contents/Resources/"
cp -R "$prototype_dir/ThirdParty" "$app_dir/Contents/Resources/ThirdParty"
cp "$workspace_dir/LICENSE" "$app_dir/Contents/Resources/LICENSE"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.franke.Whisky.CrossUI</string>
<key>CFBundleName</key><string>WhiskyCrossUI</string>
<key>CFBundleDisplayName</key><string>Whisky · SwiftCrossUI</string>
<key>CFBundleExecutable</key><string>WhiskyCrossUI</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>WhiskyDataBundleIdentifier</key><string>com.franke.Whisky</string>
</dict></plist>
PLIST
if [[ -n "${WHISKY_CROSSUI_APP_ID:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $WHISKY_CROSSUI_APP_ID" "$app_dir/Contents/Info.plist"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d.%H%M%S)" "$app_dir/Contents/Info.plist"
python3 - "$workspace_dir" "$app_dir" <<'PY'
import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import sys
root, app = map(Path, sys.argv[1:])
sources = sorted({path for folder in [root / 'WhiskyCore/Sources', root / 'WhiskyKit/Sources',
                                     root / 'experimental/SwiftCrossUI/Sources']
                  for path in folder.rglob('*.swift')})
record = {
    'built_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'branch': subprocess.check_output(['git', 'branch', '--show-current'], cwd=root, text=True).strip(),
    'base_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
    'compiler_output_sha256': hashlib.sha256((app / 'Contents/MacOS/WhiskyCrossUI').read_bytes()).hexdigest(),
    'sources': {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources},
}
(app / 'Contents/Resources/BuildInfo.json').write_text(json.dumps(record, indent=2) + '\n')
PY
plutil -lint "$app_dir/Contents/Info.plist"
codesign --force --deep --sign - "$app_dir"
if [[ -e "$destination" ]]; then mv "$destination" "$staging_dir/previous.app"; fi
mv "$app_dir" "$destination"
python3 - "$destination" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
app = Path(sys.argv[1])
record = json.loads((app / 'Contents/Resources/BuildInfo.json').read_text())
record['signed_binary_sha256'] = hashlib.sha256((app / 'Contents/MacOS/WhiskyCrossUI').read_bytes()).hexdigest()
app.with_suffix('.build.json').write_text(json.dumps(record, indent=2) + '\n')
PY
printf '%s\n' "$destination"
