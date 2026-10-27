# Whisky GE Wine fork

This fork keeps Whisky's UI, bottle management and `Libraries.tar.gz` installer.
Its Wine runtime comes from `daydalek/ge-proton-macos-wine-poc`, using the `media`
variant with GE-Proton's multimedia patches and the macOS adaptations.

## Release contract

Publish these assets in a published release (stable or prerelease) in
<https://github.com/daydalek/ge-proton-macos-wine-poc/releases>:

| Asset | Purpose |
| --- | --- |
| `WhiskyWineVersion.plist` | Runtime version, DXVK version and archive SHA-256 |
| `Libraries.tar.gz` | Whisky-compatible runtime installation tree |
| `SHA256SUMS` | Command-line integrity verification |
| Corresponding sources archive | Wine/GE patches, dependencies and build recipes for this exact binary |

The plist's runtime version uses `X.Y.Z` and increases monotonically. The download URLs come from the selected release's assets, so release tags can include prerelease suffixes.
Runtime release versions are independent of the Wine upstream version. The first
local integration uses `11.0.1`, which also upgrades the locally installed
`11.0.0` runtime.

The app fetches the public static manifest at:

```text
https://raw.githubusercontent.com/daydalek/ge-proton-macos-wine-poc/runtime-channel/WhiskyWineVersion.plist
```

The channel publisher runs with an authenticated CI token, checks complete release
assets (stable or prerelease) and their SHA-256, then writes the public runtime
fields and exact `downloadURL` to the dedicated branch. The app uses public HTTPS
for both metadata and archive downloads. Normal update checks share a one-hour
cache; initial setup and explicit retries refresh immediately.

The existing `v0.1.0` prerelease now carries the compatible `Libraries.tar.gz`
and version plist as well as its original portable package. Its runtime version
is `11.0.1`; the explicit URL in the static manifest preserves this distinction.

The Wine build/release CI refreshes the channel after publishing. The separate
**Publish Wine runtime channel** workflow also runs on release publication or edits.
After adding assets to an existing release, dispatch that workflow to update the
channel. Incomplete releases preserve the current channel. Changed archives
require an increased runtime version; older versions keep the newer channel.

## Assemble locally

Build the `media` stage and dependencies in the core repository first, then:

```sh
python3 scripts/assemble-ge-runtime.py \
  --poc /path/to/ge-proton-macos-wine-poc \
  --base-libraries '/path/to/existing/Libraries' \
  --version 11.0.1 \
  --output build/ge-runtime/11.0.1
```

The base runtime supplies the existing DXVK-macOS payload and its recorded
version. The script copies the `media` Wine core and FFmpeg/FreeType/MoltenVK
dependencies, rewrites Mach-O dependency paths, adds relative rpaths, applies
ad-hoc signatures, and creates `Wine/bin/wine64 -> wine`. It records the actual
minimum macOS version, source repository revision, and dependency audit in
`Libraries/GE-Media/runtime-manifest.json`. The inner version plist describes
the installed runtime; the outer plist additionally contains the archive digest.

The initial payload includes DXVK and wined3d. DXMT requires validation of the
matching winemetal Unix bridge against this Wine build. D3DMetal requires GPTK
exception support and the separately licensed Apple payload. These capabilities
remain gated by the existing runtime metadata and payload checks.

Whisky sets `WINELOADER`, `WINESERVER` and `DYLD_FALLBACK_LIBRARY_PATH` to the
installed core. Existing environment precedence still lets program settings
override the dependency search path.

## Acceptance and publication

Prepare a separate public copy before uploading the two runtime assets:

```sh
python3 scripts/prepare-ge-release.py \
  --input build/ge-runtime/11.0.1/Libraries \
  --output build/ge-runtime/11.0.1-public \
  --objcopy /path/to/llvm-objcopy \
  --private-name "$(id -un)"
```

This strips debug information, removes SDK headers/import archives, remaps local
build paths with fixed-size substitutions, re-signs Mach-O binaries, scans the
final payload, and anonymizes tar owner fields. Publish the archive and plist
from this public output directory. Keep the local audit and probe logs locally.

1. Extract `Libraries.tar.gz` into a fresh directory and verify its SHA-256,
   `Wine/bin/wine64 --version`, and relative symlinks.
2. Create an isolated prefix with the extracted core. Run 32/64-bit command-line,
   device-notification, multimedia and Vulkan probes from the core project.
3. Use the freshly built Whisky app to test bottle creation, Winecfg, a 32-bit
   video game and a DXVK title. Record visual playback and graphics results.
4. Attach the exact corresponding sources and notices. The local script records
   the checkout revision; source/build correspondence must be verified for the
   selected stage before publication.
5. Publish the release (stable or prerelease) with the four asset groups above.
   Dispatch **Publish Wine runtime channel**, verify the fixed manifest URL, then
   perform a fresh download/install through Whisky.

The assembled local core currently requires macOS 27 and Rosetta 2. Ad-hoc
runtime signatures support local testing; a public app DMG follows the existing
Developer ID signing and notarization workflow in `ReleaseWorkflow.md`.

Application automatic updates and the Sparkle update menu are disabled in this fork.
Wine runtime updates remain active.

## Automatic application releases

`AppRelease.yml` builds the app when a `vX.Y.Z` or `app-vX.Y.Z` tag is pushed to
this fork. It runs WhiskyKit tests, builds the Release configuration for arm64,
checks bundled dependencies and translations, signs the app with an ad-hoc
identity, and verifies the ZIP after extraction. The workflow creates a draft
Release in the current repository, uploads all assets, then publishes a prerelease.

After committing the fork changes and configuring its Git remote:

```sh
git tag -a v0.1.0 -m 'Whisky GE fork 0.1.0'
git push origin v0.1.0
```

Assets include `Whisky-0.1.0-arm64.zip` containing `Whisky.app`, `SHA256SUMS`,
`build-info.json` and release notes. Wine Libraries are downloaded separately.
Manual workflow runs accept an app version and retain the ZIP as an Actions
artifact. Ad-hoc app releases require macOS first-launch approval.

For a local packaging check, use `./build.sh run whisky-macos-gpui-arm64 --version 0.1.0`.
Each run uses a fresh output directory. The existing Homebrew workflow is restricted to its upstream
repository.
