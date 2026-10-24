# Linux Wine download and update contract

The Linux frontend exposes first-install setup and **Settings → Wine runtime →
Install or update runtime**. Startup checks follow `checkWhiskyWineUpdates` and
`offlineMode`. A detected release produces a notice; installation starts from
the install/update action. Backend jobs remain pollable and cancellable.

## Publisher and release selection

The producer is [daydalek/ge-proton-macos-wine-poc](https://github.com/daydalek/ge-proton-macos-wine-poc),
whose [Linux contract](https://github.com/daydalek/ge-proton-macos-wine-poc/blob/codex/linux-support/README.linux.md#frontend-runtime-contract)
declares these assets and entrypoints:

| Item | Contract |
| --- | --- |
| Archive | `wine-linux-amd64.tar.gz`, with top-level `wine-linux-amd64/` |
| Checksums | `SHA256SUMS-linux-amd64`, including archive and manifest hashes |
| Manifest | `linux-release-manifest.json` |
| Wine command | `run`; executable loader `bin/wine`; server `bin/wineserver` |
| Prefix | `WINEPREFIX` supplied by Whisky, architecture `win64` |
| CPU | x86_64 Unix executables; new WoW64 Windows modules |

Whisky reads the repository's GitHub Releases API, including prereleases. It
selects the highest numeric version with all three required uploaded assets,
accepting `vMAJOR.MINOR.PATCH` and `vMAJOR.MINOR.PATCH-linux-amd64`. Drafts and
platform-specific releases carrying other assets stay outside this selection.
The existing `runtime-channel/WhiskyWineVersion.plist` serves macOS Libraries.

The consumer checks asset names, exact repository/tag download URLs, size
limits, manifest entrypoints and architecture, SHA-256 sums and the GitHub
archive digest when available. It then validates the archive's ELF class/CPU,
executable entrypoints and extraction boundaries. Python 3.12+ performs bounded
streaming hashing and `tarfile` data-filter extraction in a private directory;
the Linux runtime dependency list includes Python. The validator ships as the
`WhiskyBridge_WhiskyApplication.resources` SwiftPM resource bundle beside the helper.

## Runtime ownership and activation

The helper applies this priority:

1. `--wine-runtime` or `WHISKY_WINE_RUNTIME`: a fixed external runtime, with its
   existing Wine commands and status. The external owner controls its updates.
2. A verified managed generation selected by
   `$XDG_DATA_HOME/whisky/runtime/wine/current`; the data-home fallback is
   `~/.local/share`.
3. `WHISKY_WINE_FALLBACK_RUNTIME`, or a sibling `wine/` discovered beside the
   application. The bundled tree remains available while a managed update is installed.

The Ubuntu test-bundle launcher exports the fallback variable. Existing
launchers that export `WHISKY_WINE_RUNTIME` select the fixed-path mode; rebuilding
the launcher adopts the managed-update convention. Explicit emulator commands
continue wrapping the ELF loader/server; native and binfmt execution use `run`.

An installation holds a nonblocking process-shared lock, downloads into its
own staging directory, verifies the payload, records its release metadata and
atomically switches the `current` symlink. Previous generations remain intact.
Hosts resolve the selected generation once, retaining a stable path during use.
Registered Wine servers are checked before download and again before activation.
Checksum/format errors, short downloads, cancellation and late busy checks keep
the previous selection. An older remote version keeps the newer local version;
a changed archive at the same version produces `version_conflict`.

`setup.status.path` always returns a string, including during first installation.
A completed activation sets `restartRequired`; the frontend finishes its other
background jobs and reconnects the helper before showing installation completion.
An already-current result preserves the existing session. Update-check jobs
participate in the polling timer, including with an empty library.

## Validation and reproduction

OrbStack ARM Ubuntu 24.04, Swift 6.4 and Rust 1.99.1 exercised the production
helper over real local HTTP: first install, restart discovery, upgrade,
previous-generation retention, checksum/unsafe-link/short-download rejection,
downgrade protection, offline preferences and cancellation. Xvfb/Mesa drove the
actual GPUI window through first install, settings update, helper reconnection,
quit/restart and startup detection of the next fixture version. CI runs these
bounded local fixtures and the clean-runtime package gate runs them after relocation.

The current Swift 6.4 gate passes Core 116, Metadata 20 and Bridge 117 cases;
the explicit Rust SDK gate passes its real-helper and transport integration
tests. GPUI passes 127 tests on Linux and macOS. Native macOS adapter tests pass
12 cases. The bridge suite keeps the public-network case opt-in; local checks
also run it explicitly. macOS archive fixtures can be enabled with
`WHISKY_TEST_PYTHON=/path/to/python3.12`; ordinary macOS tests retain their
existing Python environment and skip those Linux archive fixtures.

```sh
python3 apps/whisky-gpui/tools/check-linux-wine-update.py \
  --helper /path/to/whisky-bridge --output /tmp/wine-update-evidence
xvfb-run -a -s '-screen 0 1280x900x24 -nolisten tcp' dbus-run-session -- \
  env GDK_BACKEND=x11 WGPU_BACKEND=vulkan \
  python3 apps/whisky-gpui/tools/smoke-wine-update.py \
    --binary /path/to/whisky-gpui --helper /path/to/whisky-bridge \
    --output /tmp/wine-update-window
```

`--real-release` on the helper check additionally downloads the public release.
Local evidence under `build/portability/wine-update/production-http/report.json`
records the published `v0.1.6-linux-amd64` payload, SHA-256
`2abd9cfdea9e262243d272edce89ea200e704858382686641b3a7ca700c9c611`.
The producer marks this payload `compile-only`. Download/install verification
and Wine/game execution have distinct acceptance evidence.

### Clean runtime evidence, 2026-10-24

Implementation commit `e68147ffb3fbbe4be5201feb692a5f762a40daf9` was packaged
from a clean tree into a development-binary validation archive, carrying 17
Swift runtime libraries and 1,490 inventoried files. Archive SHA-256:
`340918f77b094a2de485aeb07b91b19c978979a44c2a75f65090d686484a9dca`.
The optimized Release build remains the CI `build-linux-release.sh` path.

The archive passed all 16 checks as `whisky-test` (UID 10001) in a clean Ubuntu
24.04 image with network mode `none`, compilers absent and the source/build
workspace outside the container. After relocation into a Unicode/quote/literal
`$HOME` path, the real helper and window passed Wine install, upgrade,
cancellation, failure preservation and startup update detection over local HTTP.
The archive validator resource was resolved from the packaged SwiftPM bundle.
Final bundle hashes remained intact. Reports and screenshots are retained under
`build/portability/wine-update/clean-runtime-evidence/`; its `report.json`
records the implementation commit and archive checksum.

Swift 6.0 also passes Core 116, Metadata 20 and Bridge 117 cases. The controlled
window channel installs fixture 0.1.6, upgrades to fixture 0.1.7 and detects
fixture 0.1.8 after restart. The separate public-network evidence records the
actual published 0.1.6 payload and its producer checksum above.
