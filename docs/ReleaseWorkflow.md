# Release Workflow

This document describes the current release paths for `daydalek/Whisky` and its companion Wine runtime.

## Release streams

| Stream | Repository | Tags | Main artifact |
| --- | --- | --- | --- |
| Whisky app | `daydalek/Whisky` | `vn-vX.Y.Z`, `app-vX.Y.Z`, or `vX.Y.Z` | `Whisky-X.Y.Z-arm64.zip` |
| Whisky Linux GPUI | `daydalek/Whisky` | `linux-vX.Y.Z` | deb, rpm and AppImage |
| Wine Libraries | `daydalek/ge-proton-macos-wine-poc` | `vX.Y.Z` | `Libraries.tar.gz` |

The app workflow publishes prereleases with ad-hoc signatures. Users download and replace the app manually. The current Wine runtime requires macOS 27+ on Apple Silicon with Rosetta 2; the app target itself has a macOS 15.0 deployment target.

## App release

The authoritative macOS GPUI workflow is [AppRelease.yml](../.github/workflows/AppRelease.yml), which invokes `./build.sh run whisky-macos-gpui-arm64`. Linux GPUI uses [LinuxRelease.yml](../.github/workflows/LinuxRelease.yml) and its reusable distribution and package acceptance jobs.

### Prepare the release

1. Review the changes and update `CHANGELOG.md` for the app version.
2. Run the relevant checks before tagging. The macOS release workflow also runs WhiskyBridge and GPUI tests before building; Linux runs shared-core, bridge, GPUI and package checks.
3. Choose the app version `X.Y.Z`. The workflow derives the version from the tag and supplies the build number from `github.run_number` at build time. macOS and Linux use independent version streams.

### Build and publish

For example, after committing the release changes:

```sh
git tag -a vn-vX.Y.Z -m "Whisky X.Y.Z"
git push origin vn-vX.Y.Z
```

Pushing a matching tag runs the app release workflow. It builds an arm64 Release app, applies ad-hoc signatures to executable files and nested bundles, verifies the signatures, packages the ZIP, and verifies the extracted app again.

The workflow uploads these assets, checks `SHA256SUMS`, and publishes a GitHub prerelease in this repository:

- `Whisky-X.Y.Z-arm64.zip`
- `SHA256SUMS`
- `build-info.json`
- `RELEASE-NOTES.md`

An existing release for the same tag has its matching assets replaced and its prerelease metadata updated. Treat a tag push as authorization to publish those assets.

To build for review through Actions, run **Build and release Whisky app** with `workflow_dispatch` and supply `version: X.Y.Z`. Manual runs upload the `whisky-app-release` Actions artifact for inspection.

For a local package:

```sh
BUILD_NUMBER=123 bash scripts/build-app-release.sh X.Y.Z
```

Use a suitable numeric build number. Output goes to `build/app-release/assets/`; the script requires that directory to be absent at the start. Move an earlier output aside before running another package build. Local builds use the same ad-hoc signing and ZIP verification path.

### Signing and update behavior

Current ZIP releases use ad-hoc signatures and require the user's Gatekeeper approval where applicable. Apple notarization is a separate distribution step.

`WhiskyApp` creates the Sparkle controller with `startingUpdater: false`. The current app upgrade path is manual download from [app Releases](https://github.com/daydalek/Whisky/releases). `dist/pages/appcast.xml` is an empty feed for this fork.

`scripts/release.sh` and `scripts/exportOptions.plist` remain as the inherited Developer ID / notarized DMG tooling. Their certificate, notarytool and Sparkle key setup belongs to a separately configured DMG distribution path. The active ZIP workflow is defined in `AppRelease.yml`.

`UpdateHomebrewTap.yml` is scoped to `github.repository == 'frankea/Whisky'` and updates the upstream maintainer's tap. This fork distributes its app through GitHub Releases.

## Wine Libraries release

Wine is built and published in [daydalek/ge-proton-macos-wine-poc](https://github.com/daydalek/ge-proton-macos-wine-poc). Its release workflow and `scripts/ci/build-release.sh` define the build inputs and packaging steps.

The current build compiles the locked CrossOver Wine 26.3 source with the GE multimedia port and compatibility patches, builds the locked dependencies, and assembles the Whisky Libraries tree with digest-pinned DXVK-macOS 1.10.3 and MoltenVK. The distributed tree contains `Wine/`, `DXVK/`, `GE-Media/`, and `WhiskyWineVersion.plist` under `Libraries/`.

1. Update and validate the source locks, dependency locks and patch series in the Wine repository as required.
2. Run its source checks. Branch pushes and pull requests run source checks; `v*` tag pushes and full manual runs also build Libraries on the configured macOS 27+ runner with Rosetta 2.
3. Push a `vX.Y.Z` release tag in the Wine repository. The workflow builds, verifies, checks archive digests, publishes a prerelease and refreshes the public runtime channel.
4. Inspect the published assets and reports. Record target-device game playback acceptance separately from static build checks.

The release publishes:

- `Libraries.tar.gz` and `Libraries-sources.tar.gz`
- `WhiskyWineVersion.plist` and `SHA256SUMS`
- `release-manifest.json` and `RELEASE-NOTES.md`
- `Libraries-privacy-audit.json`, `Libraries-static-check.json`, and `Libraries-ffmpeg-capabilities.json`

The corresponding source archive carries the prepared source and build material. Use the Wine repository's locks, source archive and reports to audit the specific release.

The `libraries_only` manual option selects a legacy released-runtime packaging check. Use the full build path to validate the current source and FFmpeg configuration.

### Runtime channel

`scripts/ci/publish-runtime-channel.py` in the Wine repository validates published assets and writes `WhiskyWineVersion.plist` to the `runtime-channel` branch. It runs after a tagged build is published and through the separate **Publish Wine runtime channel** workflow on release publication/editing or manual dispatch.

The manifest records the exact release asset `downloadURL`, the archive SHA-256, runtime version and component metadata. Formal releases and prereleases can supply channel updates.

The runtime version is generated as `11.0.(GITHUB_RUN_NUMBER + 1)` and is independent of the public release tag. The app compares this runtime version for update prompts. Normal checks share a one-hour in-process manifest cache; setup and explicit retries request fresh metadata. The app validates the manifest URL and SHA-256 and verifies the downloaded archive before installing it.

The shared runtime installs at `~/Library/Application Support/com.franke.Whisky/Libraries/`.

## Pages and distribution URLs

[Documentation.yml](../.github/workflows/Documentation.yml) is manually dispatched. It generates API documentation, overlays `dist/pages/`, and deploys the result through GitHub Pages. App and Wine release workflows publish their own artifacts independently of this Pages deployment.

| Purpose | URL |
| --- | --- |
| App downloads | `https://github.com/daydalek/Whisky/releases` |
| App ZIP example | `https://github.com/daydalek/Whisky/releases/download/vn-vX.Y.Z/Whisky-X.Y.Z-arm64.zip` |
| Active Wine manifest | `https://raw.githubusercontent.com/daydalek/ge-proton-macos-wine-poc/runtime-channel/WhiskyWineVersion.plist` |
| Wine archive example | `https://github.com/daydalek/ge-proton-macos-wine-poc/releases/download/vX.Y.Z/Libraries.tar.gz` |
| Configured Sparkle feed | `https://daydalek.github.io/Whisky/appcast.xml` |

`dist/pages/WhiskyWineVersion.plist` is a static Pages file. The app's active Wine update source is the `runtime-channel` URL defined in `DistributionConfig`.

## Packaging checks

- Keep `build-info.json`, release notes and `SHA256SUMS` together with the exact ZIP produced by the build. Repackaging changes the archive digest.
- Keep WhiskyKit's `.build` directory outside app resources. Build tools and intermediate products belong outside the distributed app bundle.
- Drain subprocess output pipes before calling `waitUntilExit()`. Verbose tar listings can fill the pipe buffer during runtime extraction or validation.
