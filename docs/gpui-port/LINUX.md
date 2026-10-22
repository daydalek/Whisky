# Linux adaptation and headless verification

The Linux product path is `apps/whisky-gpui` plus the Swift `whisky-bridge`
child process. The active target covers the application's Linux functionality
with Wine execution excluded. Work continues through the remaining services
and distribution gates below.

## Verified on 2026-10-23

OrbStack ARM64 Ubuntu 24.04, Swift 6.4, Rust 1.99.1, Xvfb/X11 and Mesa software
rendering:

- Shared core: 112 tests; portable bridge: 44 tests; shared metadata package: 20 tests.
- Rust SDK tests, including its real Swift helper integration test.
- Production GPUI Linux build/link and 118 unit tests.
- Production Rust client/helper handshake, capability list and isolated empty
  library reads, with the display environment absent.
- XDG preferences survive a real helper process exit/restart. File-backed
  preferences reload under a process-shared lock, preserve unknown fields,
  validate patches and retain corrupt files for recovery.
- Real production window: library, Ctrl+, settings, Ctrl+Alt+S sidebar,
  Ctrl+Q graceful exit and persisted window dimensions. Captured screenshots
  show the library and Chinese settings text using Noto Sans CJK SC.
- macOS GPUI's 118 tests and the macOS bridge suite also pass.

The program-storage stage adds full `programs.settings.read/set` and
`programs.history.read/delete` to the portable helper. Both Linux and macOS now
use these shared file services; macOS supplies its existing bottle defaults and
log directory. Native model compatibility is covered by 11 macOS adapter tests.
The program checks also verify:

- Legacy settings load through the original fallback path and migrate to the
  identity path on save, preserving unknown settings and override keys.
- Locale presets, literal arguments/environment, every override group, tagged
  HUD/sync enums, DLL overrides and verb tags persist across helper restarts.
- Six independent helper processes update distinct fields concurrently and
  retain every edit. Invalid patches leave the stored document intact.
- Imported run history retains unknown data; selective deletion removes only
  the chosen record and its regular log file. Imported traversal paths produce
  a visible error and preserve the original document.
- The seeded production window opens a real pinned game's settings, edits its
  arguments, saves to the identity plist and reloads the edited value. Closing
  the editor restores root focus for the desktop shortcuts.

The process and window evidence is recorded in
`program-settings-full-linux.log`, `program-settings-macos.log`,
`program-gpui-macos.log`, `linux-gpui/programs/report.json` and
`linux-gpui/program-window/`. These window scenarios run in the Linux CI job.

## Shared metadata and artwork stage

`WhiskyMetadata` now owns the existing public-provider implementations and
metadata/artwork storage. WhiskyKit keeps its public names through typealiases
and supplies the existing network preference policy. The bridge exposes all six
`metadata.*` methods on Linux, with `metadata.edit` in the handshake, and checks
the live XDG offline preference before transport. The portable program-settings
service also advertises `programs.settings`.

The package retains the existing storage keys, manual-unlink markers, cover
settings and provider snapshots. ImageIO serves macOS; GdkPixbuf plus
`webp-pixbuf-loader` serves Linux. Complete PNG, JPEG, GIF and WebP decode tests
pass on both platforms. The image-property path on macOS continues to read
dimensions independently from full pixel validation used during import.

The headless acceptance adds:

- Real helper attach/read/detach, custom-cover import, corrupt-image rejection,
  cover reset and preservation of the original prefix/program-settings bytes.
- Search jobs and cached thumbnails from controlled provider responses, with
  all four existing provider parsers exercised in the shared package tests.
- Automatic matching that retires completed markers under the folder lock and
  preserves roots, executable mappings, pending matches and unknown fields
  written while a network request was in flight.
- An actual Bangumi query for `CLANNAD`, returning source ID `13` and a cached
  thumbnail. This run's evidence is `metadata-live.log` and
  `linux-gpui/metadata-live/report.json`; external availability belongs to that
  recorded run.
- A real GPUI window displaying attached metadata and a custom image, then
  unlinking metadata and resetting the cover through the visible controls.
  File state, desktop shortcuts and graceful exit all pass. Evidence is under
  `linux-gpui/metadata-window/`.

The existing Swift 6.0 ARM Ubuntu bridge lane passes in a separate container;
the production GPUI lane passes with Swift 6.4. Swift 6.4 uses the native SwiftPM
engine for metadata and bridge tests because its default engine duplicates a
C-module dependency when constructing the test runner. The first complete run
also recorded a Python SDK fixture handshake EOF; the targeted SDK recheck and
subsequent full gates pass. The SDK recheck is recorded in `metadata-sdk-recheck.log`.

macOS validation includes 20 metadata tests, 39 portable bridge tests, 11 native
adapter tests, 24 WhiskyKit Swift Testing regressions and 2 XCTest network tests.
The full SwiftUI app compiles with the project's existing
`SKIP_SWIFTLINT_BUILD_PHASE=YES` switch. The initial strict-lint build records
pre-existing repository lint findings; the new package's generated tree is now
excluded, and the new metadata sources/adapters/tests pass targeted strict lint.
Build logs are `metadata-swiftui-build.log` and `metadata-swiftui-compile.log`.

The GameDB recommendation area still calls native-only `gameConfig.*` methods.
The current Linux window records that gap; portable recommendations and their
UI completion state remain required work.

The keyboard pass found a missing root focus path. The root view now owns a
focus handle, allowing actions to bubble from child text fields as well as
the initially focused root. Linux uses Ctrl shortcuts; macOS retains Command.

Local logs and screenshots are under `build/portability/gui-linux/`:
`gpui-check.log`, `bridge-macos-test.log`, `gpui-macos-test.log`, and
`linux-gpui/window/{report.json,library.png,settings.png,sidebar-toggled.png}`.
The tracked scripts and CI job reproduce the checks; hosted CI execution
requires an actual workflow run.

## Native Linux file-dialog stage

The Linux bridge now exposes `system.chooseFolder`, `system.chooseFolders` and
`system.choosePath`, with `system.picker` in the handshake. A sibling SwiftPM
product, `whisky-file-picker`, owns a GTK4 native chooser and its display loop.
Distribute both executables together. GTK4 joins GdkPixbuf as a Linux build and
runtime dependency; the installer also provides the AT-SPI tools used by CI.

The helper passes literal argv and receives NUL-delimited UTF-8 paths, covering
newlines, pipe characters and other valid filename characters. A POSIX child
runner drains bounded output, enforces deadlines and cancellation, and reaps
its child. Child exit completes the request even when a descendant retains a
pipe. Spawn restores a normal signal mask for children of Swift executor
threads, allowing the chooser to exit when its bridge parent dies. The Rust client
allows 330 seconds for dialog requests; the native chooser closes at 300 seconds.

Headless Xvfb/AT-SPI acceptance drives real file, directory, multiple-directory
and save dialogs. It verifies a prefilled Chinese save filename, an unwritten
save destination, literal special characters and a cancelled dialog followed
by another usable bridge request. Actual chooser deadlines and bridge-parent
termination also pass. The production GPUI metadata window also
waits six seconds in the chooser and then imports the selected image. Both
flows run in the Linux CI job and preserve screenshots and JSON reports.

Local evidence is `picker-full-linux-final.log`, `picker-final-linux.log`,
`picker-swift60-final.log`, `picker-gpui-final.log`, `picker-macos-test.log`,
`picker-gpui-macos.log`,
`linux-gpui/pickers-native/` and `linux-gpui/picker-gpui-window/` under
`build/portability/gui-linux/`. The Swift 6.0 ARM lane and Swift 6.4 production
lane cover the new C/GTK target as well as 112 core, 20 metadata and 44 bridge
tests. macOS retains its native dialog adapter and passes 44 shared bridge plus
11 native-adapter tests; the GPUI suite passes 118 tests on each platform.

Swift 6.4's bundled Clang accepts SwiftPM's index-store flag. The Linux scripts
select `clang-21` when available and preserve explicit `CC`/`CXX` overrides;
this toolchain's C++ invocation also uses `clang-21`.

A final window recheck observed transient `ENOENT` while the cover-settings
snapshot was being replaced on the shared mount. The acceptance script now
retries missing snapshots within its existing deadline and verifies the final
persisted state. The repeat window run is recorded in `picker-gpui-final.log`.

## Reproduce

Use an Ubuntu 24.04 environment with Swift 6.4 and Rust 1.99.1. Install the
system dependencies as root, then run the checks as the build user:

```sh
bash apps/whisky-gpui/tools/install-linux-deps.sh
export WHISKY_LINUX_OUTPUT="$PWD/build/portability/linux-gpui"
bash apps/whisky-gpui/tools/check-linux.sh
xvfb-run -a -s '-screen 0 1280x900x24 -nolisten tcp' dbus-run-session -- \
  env GDK_BACKEND=x11 WGPU_BACKEND=vulkan \
  python3 apps/whisky-gpui/tools/smoke-linux.py \
    --binary "$WHISKY_LINUX_OUTPUT/rust-build/debug/whisky-gpui" \
    --helper "$WHISKY_LINUX_OUTPUT/foundation/bridge-build/debug/whisky-bridge" \
    --output "$WHISKY_LINUX_OUTPUT/window"
# Repeat with a seeded program and actual settings edits:
# use --output "$WHISKY_LINUX_OUTPUT/program-window" --scenario programs
# Drive all native chooser modes and their cleanup checks:
xvfb-run -a -s '-screen 0 1280x900x24 -nolisten tcp' dbus-run-session -- \
  env GTK_A11Y=atspi GDK_BACKEND=x11 \
  python3 apps/whisky-gpui/tools/smoke-pickers.py \
    --helper "$WHISKY_LINUX_OUTPUT/foundation/bridge-build/debug/whisky-bridge" \
    --output "$WHISKY_LINUX_OUTPUT/pickers"
```

The source tree can be mounted read-only; set `WHISKY_LINUX_OUTPUT` to a writable
directory. Cargo downloads the locked dependency graph on its first run.
The window check uses an isolated registry, preferences and window-state file.

Linux application preferences live in
`$XDG_CONFIG_HOME/whisky/preferences.plist`, falling back to
`~/.config/whisky/preferences.plist`. The existing SwiftUI-compatible macOS
UserDefaults backend continues to serve macOS callers.
Imported program logs resolve under `$XDG_STATE_HOME/whisky/logs`, with
`~/.local/state/whisky/logs` as the Linux fallback.

## Remaining gates for the full target

| Area | Current evidence | Required work |
| --- | --- | --- |
| Library and configuration | Shared storage tests; empty production window and CLI | Seeded-library folder edits through the native chooser, persisted ratings/visibility and refresh/recovery |
| Program settings and history | Complete shared file services, native-model compatibility, concurrent real helpers and seeded UI writes/reload | Linux shortcut creation is tracked under host integration; broader UI override editing remains in the desktop gate |
| Metadata and covers | Shared package, six portable bridge methods, real provider search and seeded UI import/unlink/reset | Broader search/apply interactions in the desktop gate; portable GameDB recommendations |
| Container lifecycle | macOS native bridge implements rename/remove/move/duplicate/export | Portable lifecycle, import/orphan scan and filesystem acceptance on isolated fixtures |
| Host integration | XDG registry/preferences; file open/reveal adapter; GTK file/folder/save dialogs | Terminal discovery, desktop/file associations and capability-aware settings |
| Diagnostics | macOS report/check adapter | Linux host information, file export and appropriate platform checks |
| Distribution | macOS `.app` packaging | Linux relocatable bundle, Swift runtime libraries, launcher/desktop entry and clean-environment acceptance |
| Desktop acceptance | ARM64 X11 virtual display with Mesa | Seeded end-to-end interactions, restart/recovery and Wayland coverage; x86_64 hosted CI evidence |

Wine installation, Windows process execution and game compatibility follow the
user's explicit scope exclusion. File editing and host integration remain part
of the Linux adaptation target.
