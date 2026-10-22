# Linux adaptation and headless verification

The Linux product path is `apps/whisky-gpui` plus the Swift `whisky-bridge`
child process. The active target covers the application's Linux functionality
with Wine execution excluded. Work continues through the remaining services
and distribution gates below.

## Verified on 2026-10-23

OrbStack ARM64 Ubuntu 24.04, Swift 6.4, Rust 1.99.1, Xvfb/X11 and Mesa software
rendering:

- Shared core: 112 tests; portable bridge: 63 tests; shared metadata package: 20 tests.
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

## Portable container lifecycle stage

Linux now publishes `bottle.rename`, `bottle.duplicate`, `bottle.move`,
`bottle.remove` and `bottle.export`, with `bottle.lifecycle.file` in the
handshake. macOS keeps its existing native dispatch and runtime enablement
boundary. File-only lifecycle tests also run directly against the shared
service on macOS. Explicit `--container` workspaces retain their read-only
registry boundary for lifecycle changes.

A nonblocking registry lease serializes independent helpers. Registry writes
preserve unknown plist fields, and rename preserves the registry bytes. Long
operations use retained bridge jobs and release the main actor. Copy checks
cancellation between files and removes its owned partial clone on cancellation
or failure. Clone cleanup follows the existing native policy for root `logs/`
files and diagnosis-history sidecars; nested game logs remain intact.

Moves preserve relative program identities and rewrite declared absolute pins,
blocklists, folder roots/executable mappings and internal absolute symlinks.
External symlink targets remain intact. Registry aliases are resolved before
the original directory moves. Same-filesystem moves use an atomic exclusive
rename, preserving an existing destination. Cross-device moves complete the
copy and metadata rewrite before committing the registry and cleaning the
source. An exception before the registry commit restores the original move;
cleanup/recovery failures report the retained path through `recovery_required`.

Removal supports keeping the files or deleting the registered tree. Physical
removal first stages the directory under a private sibling name; a registry
write failure restores that directory. Exports create a private temporary
archive and publish a completed gzip tar through an exclusive hard link.
Archive members are rooted at the container's basename. These operations use
isolated fixtures for acceptance; active Wine-process handling remains within
the excluded runtime scope.

Verification covers 52 shared bridge tests on macOS and ARM Ubuntu, 11 macOS
native-adapter tests, the Rust SDK integration and 118 GPUI tests per platform.
Real Linux helpers additionally verify restart readback, all five operations,
copy cancellation, external symlink preservation, registry-field preservation,
and cross-device moves using both the shared mount and `/dev/shm`. The
production window renames a seeded container through its sidebar menu and
reads back the actual metadata. Closing a lifecycle dialog restores root focus
for Ctrl shortcuts. CI now runs these process and window checks.

Evidence under `build/portability/gui-linux/` includes
`lifecycle-macos.log`, `lifecycle-gpui-macos.log`, `lifecycle-full-linux.log`,
`lifecycle-final-linux.log`, `lifecycle-window-final.log`, `lifecycle-swift60-final.log`,
`lifecycle-tmpfs.log`, `lifecycle-tmpfs-report.json`,
`linux-gpui/lifecycle/{report.json,helper.log}` and `linux-gpui/lifecycle-window/`.
The first real-helper pass exposed a Linux URL directory-marker comparison;
canonical container URLs now carry an explicit directory identity. The first
window pass exposed lost focus after rename; the fixed window rerun passes.

## Interrupted-helper recovery stage

Directory-changing lifecycle operations reserve private copy directories and
publish a binary plist at `BottleVM.plist.lifecycle.plist` before copying
contents or moving a registered tree. The journal file is
written with mode 0600, flushed and published exclusively. The registry records
`whiskyLifecycleCommit` in the same atomic write as its new paths, establishing
the commit boundary. The journal retains directory device/inode identities,
original registry paths, and the complete metadata/link undo plan for a move.
Journal size is capped at 64 MiB before the tree changes.

Before commit, recovery removes an owned partial clone or restores a moved or
staged directory, its original settings bytes and interrupted internal links.
After commit, recovery retains the registered copy/move and finishes retiring
the old source or staged removal. Identity mismatches and corrupt journals
preserve the involved paths and journal and return an explicit error.

`workspace.recover` starts a retained job or returns a null `jobID` when the
workspace is clear. The production Rust client polls recovery before its first
container read. Each IPC request keeps its normal deadline while cleanup can
continue as a job. Normal container requests and background jobs hold shared
registry leases; lifecycle changes hold an exclusive lease. This covers the
snapshot interval before journal publication as well as the pending-journal
interval. macOS retains its existing native lifecycle enablement boundary.

The 60 shared bridge tests pass on macOS and ARM Ubuntu with Swift 6.0/6.4;
11 macOS native-adapter tests, the real Rust SDK integration and 118 GPUI tests
per platform also pass. Unit coverage includes a link interrupted between
unlink/recreate, committed clone/removal states, a replaced destination,
corrupt-record preservation and lease release on task cancellation.

Real Linux helpers are group-stopped at an observed filesystem/registry state
and terminated with SIGKILL. Four recorded cases pass: copy and same-device
move before commit, removal and cross-device move after commit. Fresh helpers
recover the original/committed trees, preserve external symlink targets and
clear successful journals. The production CLI recovers before listing the
library. A real GPUI startup after a killed copy also recovers its fixture and
passes settings, sidebar, graceful exit and persisted-window checks. CI runs
both the process interruption gate and the production-window scenario.

Evidence under `build/portability/gui-linux/` includes
`recovery-full-linux-final.log`, `recovery-macos.log`,
`recovery-gpui-macos.log`, `recovery-swift60-final.log`,
`linux-gpui/recovery/{report.json,helper.log}` and
`linux-gpui/recovery-window/`. Each process-interruption fixture preserves its
observed journal. The verified recovery scope is helper-process termination.

Required work continues with orphan discovery/import, portable route updates,
interrupted-export temporary-file cleanup and remaining lifecycle UI actions.

## Existing-container discovery and import stage

Linux exposes `workspace.discover` and `workspace.import`. Discovery scans direct
children of the configured default bottle directory and the registry-adjacent
`Bottles` directory, or an explicit `path`. It reads regular metadata files
without constructing a native Bottle, skips malformed candidates, canonicalizes
aliases and excludes registered containers. Candidates include device/inode
strings; a caller can send these back during import to reject a changed folder.

Import revalidates every selected path before a single registry commit. It
accepts one `path` or up to 128 `paths`, registers existing prefixes in place,
preserves unknown registry fields, and deduplicates aliases and concurrent
imports. A missing registry is created on successful import; corrupt registries
and pending recovery records retain their error boundary. Source metadata,
program settings, game files and symlink targets remain intact.

The Linux create-container panel now includes an existing-container import
button. The native directory chooser supplies the selected path, and the
production client reloads the persisted catalogue and library after registration.
macOS retains its existing native method boundary.

Verification adds three shared bridge regressions (63 total) on macOS and ARM
Ubuntu Swift 6.0/6.4. Six independent Linux helpers import overlapping paths
concurrently and retain exactly two canonical registrations plus unknown fields.
Full source-file hashes and symlink targets match the pre-import snapshot.
The real production window imports an orphan through GTK, displays its bottle
and pinned game, and passes settings, sidebar and graceful-exit checks. CI runs
the process gate and window scenario. Local evidence includes
`import-full-linux.log`, `import-macos.log`, `import-swift60.log`,
`import-gpui-macos.log`, `linux-gpui/import/report.json` and
`linux-gpui/import-window/` under `build/portability/gui-linux/`.

A dedicated discovered-candidate selection list remains part of the desktop
work; the current UI supports selecting an existing prefix directly. Portable
route updates, interrupted-export cleanup and remaining lifecycle UI actions
also continue as required work.

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
| Container lifecycle | Linux file lifecycle, discovery/import and SIGKILL recovery; production rename, recovery and native import UI | Discovered-candidate selection UI; portable route updates; interrupted-export cleanup; remaining lifecycle UI actions |
| Host integration | XDG registry/preferences; file open/reveal adapter; GTK file/folder/save dialogs | Terminal discovery, desktop/file associations and capability-aware settings |
| Diagnostics | macOS report/check adapter | Linux host information, file export and appropriate platform checks |
| Distribution | macOS `.app` packaging | Linux relocatable bundle, Swift runtime libraries, launcher/desktop entry and clean-environment acceptance |
| Desktop acceptance | ARM64 X11 virtual display with Mesa | Seeded end-to-end interactions, restart/recovery and Wayland coverage; x86_64 hosted CI evidence |

Wine installation, Windows process execution and game compatibility follow the
user's explicit scope exclusion. File editing and host integration remain part
of the Linux adaptation target.
