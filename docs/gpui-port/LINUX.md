# Linux adaptation and headless verification

The Linux product path is `apps/whisky-gpui` plus the Swift `whisky-bridge`
child process. The active target covers the application's Linux functionality
with Wine execution excluded. Work continues through the remaining services
and distribution gates below.

## Verified on 2026-10-23

OrbStack ARM64 Ubuntu 24.04, Swift 6.4, Rust 1.99.1, Xvfb/X11 and Mesa software
rendering:

- Shared core: 112 tests; portable bridge: 72 tests; shared metadata package: 20 tests.
- Rust SDK tests, including its real Swift helper integration test.
- Production GPUI Linux build/link and 122 unit tests.
- Production Rust client/helper handshake, capability list and isolated empty
  library reads, with the display environment absent.
- XDG preferences survive a real helper process exit/restart. File-backed
  preferences reload under a process-shared lock, preserve unknown fields,
  validate patches and retain corrupt files for recovery.
- Real production window: library, Ctrl+, settings, Ctrl+Alt+S sidebar,
  Ctrl+Q graceful exit and persisted window dimensions. Captured screenshots
  show the library and Chinese settings text using Noto Sans CJK SC.
- macOS GPUI's 122 tests and the macOS bridge suite also pass.

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

The subsequent stages below cover orphan discovery/import, portable route
updates and interrupted-export cleanup. The complete file-lifecycle window
stage below supplies the remaining file-operation UI acceptance.

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

The Linux create-container panel opens a discovered-container selection list.
It also provides a native directory chooser for direct prefix selection. The
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

The candidate-selection stage below adds batch import to this discovery API.
Portable route updates and interrupted-export cleanup are covered by the
subsequent stages; file-operation UI acceptance appears in the complete
lifecycle window stage.

## Portable route consistency stage

The Linux lifecycle now updates the registry-adjacent `GameRouting.plist` when
moving a container, including a cross-device move. The store accepts native
legacy path strings and dated `bottle` dictionaries. Patches retain their
original shapes, launch dates, opaque entry fields and unrelated/unknown keys.
Alias paths are resolved before the original directory moves and retained in
the lifecycle journal as an optional backward-compatible recovery field.

A clone keeps existing routes; deregistration that keeps files also retains
route bytes. Physical deletion prunes only numeric App-ID entries pointing at
the selected container. A missing route store stays absent. A malformed or busy
store fails before a move changes the tree. The route lock uses the same
`GameRouting.plist.lock` path as the native reader/writer, with registry-before-
route lock ordering and prompt busy errors.

The registry remains the lifecycle commit boundary. Route patches run after a
committed directory operation and before its journal clears. A failed patch
retains that journal, and recovery reapplies the patch idempotently. Before-
commit rollback retains the route file byte-for-byte. The real SIGKILL gate now
checks route contents for every recorded pre/post-commit interruption.

Verification passes 67 shared bridge tests on macOS and ARM Ubuntu Swift
6.0/6.4, plus 12 macOS native-adapter tests. The additional native test reads the
rewritten file through WhiskyKit's actual `GameRouting` API and verifies both
paths and launch dates. The full Linux production gate also passes the Rust SDK,
118 GPUI tests, real same/cross-device lifecycle, concurrent import and process-
interruption checks. All source/route fixtures are isolated and headless.

Logs are `routes-macos.log`, `routes-swift60.log` and
`routes-full-linux.log` and `routes-final-linux.log` under
`build/portability/gui-linux/`; detailed JSON
records remain under `linux-gpui/lifecycle/` and `linux-gpui/recovery/`. The new
route assertions run through the existing CI process gates.

The export stage below covers interruption cleanup. Required work continues
with the complete lifecycle window stage and the other desktop/host services.

## Export interruption and process supervision stage

Linux blocking host commands now run through a bundled C product,
`whisky-host-command`. It validates its bridge parent, creates an owned process
group and supervises the actual command. Parent death, cancellation or timeout
terminates that group, including tar's shell/compression descendants. The bridge
reaps its direct supervisor. Normal command completion retains the existing
owned-child/output-draining behavior. Ship this executable beside
`whisky-bridge` and `whisky-file-picker`; the Linux foundation gate verifies all
three products are present.

The exporter reserves a private staging file and publishes
`BottleVM.plist.export.plist` before launching tar. The record contains staging
file device/inode identity, an observed process PID/birth identity, and a
prepared flag written after successful archive completion. An exclusive hard
link publishes the completed file at the requested destination. The registry
and source prefix remain intact throughout export.

Startup recovery removes tracked partial archives and retains a published
archive whose identity matches the completed staging file. Unit coverage checks
both sides of temporary-link deletion after publication. Foreign destinations
remain intact; a replaced temporary file or corrupt journal retains evidence
and returns a recovery error. Pending export records share the existing
workspace recovery/write exclusion boundary. macOS retains native lifecycle
dispatch and passes the portable export tests directly.

Verification passes 71 shared bridge tests on macOS and ARM Ubuntu Swift
6.0/6.4, plus 12 native-adapter tests. Real helpers export a 32 MiB fixture,
observe live supervisor/tar/sh/gzip group members and then receive SIGKILL.
Every observed group member becomes inactive; the production CLI subsequently
cleans the partial archive and journal. Active-export cancellation also stops
the group and clears tracked output. A completed gzip tar is read back and its
payload hash matches the original; source metadata and registry bytes match
pre-export snapshots. The full Linux SDK/118-test GPUI gate, GTK chooser modes
and production-window import/shortcuts also pass with supervision enabled.

CI runs the new process gate and retains the observed export record. Evidence
under `build/portability/gui-linux/` includes `export-macos.log`,
`export-swift60.log`, `export-full-linux.log`, `export-final-linux.log`,
`export-final-tests-linux.log`, `linux-gpui/export-recovery/`,
`linux-gpui/pickers-export/` and `linux-gpui/export-import-window/`.

Subsequent stages cover the lifecycle window. Required work continues with the
library, metadata, diagnostics, host and distribution gates below.

## Discovered-container selection stage

The Linux import panel lists cached candidate names and canonical paths, supports
individual selection or the first 128 candidates, and offers root selection and
rescanning. It displays scanning, connection errors, import errors and completion
counts. Request generations discard stale replies; loss of the bridge clears
busy state and reconnects. Direct native prefix selection remains available.

Batch `workspace.import` accepts up to 128 candidate objects with device/inode
identity. It validates every identity before registration and rechecks the live
directories immediately before the atomic registry save. A replaced directory
causes the whole batch to fail with a rescan prompt. The frontend verifies all
acknowledged paths and identities before showing success, then reloads the
persisted catalogue. Source metadata and prefix contents retain their bytes.

Verification passes 72 shared bridge tests on macOS and ARM Ubuntu Swift 6.0/6.4,
12 macOS native-adapter tests, 122 GPUI tests on macOS and Linux, and the full
Linux core, metadata, SDK, lifecycle, import and process-recovery gates. Four new
frontend regressions cover stale replies, bounded selection, error recovery and
acknowledgement validation. A bridge regression replaces one directory in a
batch and verifies that the registry stays intact before a refreshed import.

The real production window under Xvfb exercises a root scan error, GTK root
selection, two-candidate selection, directory replacement, atomic rejection,
rescan and successful import. A separate window run verifies manual prefix
selection through the same panel. Both runs check the persisted catalogue,
source metadata, library rendering, settings, sidebar shortcut and graceful
exit. CI retains the candidate-window screenshots, logs and report. Local
evidence under `build/portability/gui-linux/` includes
`candidates-final-linux.log`, `candidates-final-swift60.log`,
`candidates-final-macos-bridge.log`, `candidates-final-macos-rust.log`,
`candidates-final-windows.log`, `linux-gpui/candidates-window/` and
`linux-gpui/candidates-manual-window/`.

## Complete container file-lifecycle window stage

The production Linux sidebar now has headless acceptance for rename, archive
export, move cancellation, move through a GTK directory chooser, duplicate,
deregistration with retained files, and physical deletion. The test reads back
the real registry after each operation, checks migrated pinned paths, preserved
opaque metadata and program settings, verifies the archived payload hash, and
confirms that external symlink targets and the deregistered clone survive
physical deletion. All fixture data stays under a fresh test directory.

Window acceptance exposed an automatic `runtime.configure` call when a moved
or duplicated container became selected on a file-only host. The supervisor
now checks the session's advertised methods before issuing that call. A test-only
transparent recorder forwards requests to the real Swift helper; the complete
window run asserts that file lifecycle requests reach production and that the
file-only session issues zero runtime configuration requests. Runtime-enabled
hosts retain the existing configuration flow.

Verification runs 122 GPUI tests on macOS and ARM Ubuntu, rebuilds the Linux
frontend, and drives the full lifecycle window under Xvfb. Screenshots cover the
archive chooser, moved and duplicated bottles, both deletion dialogs and their
persisted results, followed by settings/sidebar shortcuts and graceful exit.
CI's existing lifecycle-window step runs this expanded scenario and retains the
request trace. Local evidence lives in `build/portability/gui-linux/`:
`lifecycle-capability-macos.log`, `full-lifecycle-window-final.log` and
`linux-gpui/full-lifecycle-window/`.

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
| Container lifecycle | Linux lifecycle, routes, discovery/import and export SIGKILL recovery; complete production file-lifecycle window flow, recovery and candidate import UI | Additional platform coverage follows the desktop acceptance matrix |
| Host integration | XDG registry/preferences; file open/reveal adapter; GTK file/folder/save dialogs | Terminal discovery, desktop/file associations and capability-aware settings |
| Diagnostics | macOS report/check adapter | Linux host information, file export and appropriate platform checks |
| Distribution | macOS `.app` packaging | Linux relocatable bundle with both native helpers, Swift runtime libraries, launcher/desktop entry and clean-environment acceptance |
| Desktop acceptance | ARM64 X11 virtual display with Mesa | Seeded end-to-end interactions, restart/recovery and Wayland coverage; x86_64 hosted CI evidence |

Wine installation, Windows process execution and game compatibility follow the
user's explicit scope exclusion. File editing and host integration remain part
of the Linux adaptation target.
