# Linux adaptation and headless verification

The Linux product path is `apps/whisky-gpui` plus the Swift `whisky-bridge`
child process. Current work includes Wine runtime discovery, download and updates;
the [Linux Wine update contract](LINUX_WINE_UPDATES.md) records the publisher,
managed generations, external overrides and production-window evidence.
Work continues through the remaining services and distribution gates below.

## Verified on 2026-10-23

OrbStack ARM64 Ubuntu 24.04, Swift 6.4, Rust 1.99.1, Xvfb/X11 and Mesa software
rendering:

- Shared core: 116 tests; portable bridge: 103 tests; shared metadata package: 20 tests.
- Rust SDK tests, including its real Swift helper integration test.
- Production GPUI Linux build/link and 127 unit tests.
- Production Rust client/helper handshake, capability list and isolated empty
  library reads, with the display environment absent.
- XDG preferences survive a real helper process exit/restart. File-backed
  preferences reload under a process-shared lock, preserve unknown fields,
  validate patches and retain corrupt files for recovery.
- Real production window: library, Ctrl+, settings, Ctrl+Alt+S sidebar,
  Ctrl+Q graceful exit and persisted window dimensions. Captured screenshots
  show the library and Chinese settings text using Noto Sans CJK SC.
- macOS GPUI's 127 tests and the macOS bridge suite also pass.

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

The GameDB reference stage below now provides shared identity matching and
explicit source-platform context. Configuration application follows the
connected platform adapter capability.

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

## Linux host and file diagnostics stage

Linux advertises `bottle.diagnostics.file` with three retained-job methods:
`bottle.diagnostics`, `bottle.checks` and `bottle.exportDiagnostics`. Reports
contain distribution, kernel, CPU architecture/count, physical memory, display
session presence, registered container identity, pin count and available space.
Four platform checks cover metadata readability, `drive_c`, reported write
access and the 1 GiB free-space threshold. Read errors produce explicit warnings.
The collector uses bounded regular-file reads with `O_NOFOLLOW`/`O_NONBLOCK`;
symlinks, FIFOs, malformed and oversized metadata retain a bounded warning path.
Environment contents, program arguments and program settings stay outside the
report. Collection preserves all prefix file bytes and registry contents.

Report jobs share the registry lease and respect pending lifecycle recovery.
Exports use a private mode-0600 staging file, synchronize its complete contents,
and publish by an exclusive hard link. Existing files and symlinks remain
intact under concurrent exporters. Destinations use `.txt` outside the prefix
and registry; failed publication cleans its staging file. macOS continues its
native diagnostic dispatch, with portable collection available in shared tests.

The Linux bottle toolbar opens the existing diagnostics sheet with host/file
symptoms and localized check labels. It displays the collected report and
exports through the GTK save chooser, initially positioned outside the prefix.
Runtime audio probes remain in the Wine-dependent scope.

Verification passes 76 shared bridge tests on macOS and ARM Ubuntu Swift
6.0/6.4, plus 12 macOS native-adapter tests. The full Linux gate includes real
host collection, FIFO handling, independent concurrent exporters, private-file
permissions and complete source-hash comparisons. Both platforms pass 122 GPUI
tests. The production Xvfb window runs all four checks, displays the report,
exports it through GTK, validates its contents/permissions and source hashes,
and passes settings, sidebar and graceful-exit checks. A transparent request
trace confirms all three diagnostic methods and the file-only runtime boundary.
CI runs and retains both process and window evidence.

Local evidence under `build/portability/gui-linux/` includes
`diagnostics-macos.log`, `diagnostics-gpui-macos.log`, `diagnostics-swift60.log`,
`diagnostics-final-linux.log`, `diagnostics-window-final.log`,
`linux-gpui/diagnostics/` and `linux-gpui/diagnostics-window/`.

## Linux terminal discovery and launch stage

Linux advertises `system.terminal`, `system.terminals` and the existing
`bottle.tools` method for `tool: terminal`. Discovery reads executable files
from absolute PATH directories and returns installed terminal IDs, labels,
paths and display-session availability. The current adapters cover the system
`x-terminal-emulator`, GNOME Terminal and XTerm. Automatic selection follows
that order. An explicitly selected missing terminal returns a visible error;
a display-free process can discover terminals and receives `display_unavailable`
when opening one.

`preferredLinuxTerminal` persists independently with an `auto` default. The
Linux settings dropdown lists installed choices, shows discovered paths and
provides rescanning. The bottle toolbar enables terminal opening when a display
and the selected executable are available. The settings preserve a missing
preferred ID and prompt reselection. macOS retains its existing terminal values.

The adapter opens an interactive shell in the selected prefix with `WINEPREFIX`
set to that path. The shell and prefix are independent positional arguments to
a fixed shell script, preserving Unicode, spaces, quotes, dollar signs and
command-substitution characters. It starts the terminal asynchronously and
reaps it through Foundation; the helper remains responsive, and an opened
terminal can outlive helper shutdown. Host environment values are inherited.
The generic command interface follows [Debian terminal-emulator policy](https://www.debian.org/doc/debian-policy/ch-customized-programs.html#packages-providing-a-terminal-emulator)
and [XTerm's argument interface](https://invisible-island.net/xterm/manpage/xterm.html).
GNOME Terminal uses its command-argument delimiter.

Verification passes 80 shared bridge tests on macOS and ARM Ubuntu Swift
6.0/6.4, 12 native macOS adapter tests and 123 GPUI tests on each platform.
Four new bridge regressions cover discovery, executable type checks, literal
arguments, launch errors and independent preference persistence. A frontend
regression covers missing selected executables and display availability.

The real Ubuntu XTerm and system-terminal wrapper run under Xvfb with a probe
shell: each has an interactive PTY, exact working directory and `WINEPREFIX`,
and preserves all prefix/registry bytes. Paths contain Unicode, spaces, quotes,
`$HOME` and `$(...)`; the injection sentinel stays absent. A live terminal
survives a graceful helper shutdown. Production-window acceptance selects
XTerm, verifies persisted preferences, rescans, opens the real terminal, reads
back its PTY context and checks settings/sidebar/exit behavior. Protocol traces
cover `system.terminals` and `bottle.tools`. GNOME's argument construction has
shared-unit coverage; real-window evidence currently covers XTerm on ARM64 X11.

CI installs XTerm and runs both real-terminal and production-window scenarios.
Local evidence under `build/portability/gui-linux/` includes
`terminal-macos.log`, `terminal-gpui-macos.log`, `terminal-swift60.log`,
`terminal-final-linux.log`, `terminal-final-window.log`, `linux-gpui/terminal/` and
`linux-gpui/terminal-window/`.

## Desktop entries, file associations and startup handoff stage

Linux exposes `system.desktop.status`, `system.desktop.install` and
`programs.shortcut.create`, with `system.desktop` and `programs.shortcut`
capabilities. The settings button installs `com.franke.Whisky.desktop` under
`$XDG_DATA_HOME/applications` and refreshes the MIME application cache. Its
MimeType list adds Whisky as an available handler for Windows executables and
MSI packages. Existing `mimeapps.list` defaults retain their contents and remain
the effective default application. Missing cache tools produce an explicit
cache-refresh warning while retaining the installed entry.

Program settings create `.desktop` launchers in the XDG applications directory
or an explicitly selected existing directory. They carry the selected program
and registered prefix as separate arguments. Desktop value escaping and Exec
quoting follow the [freedesktop Exec specification](https://specifications.freedesktop.org/desktop-entry/latest/exec-variables.html).
A fixed `/bin/sh` forwarding command supports frontend paths containing `=`;
all user paths travel as positional arguments. Publication synchronizes a
private staging file and uses an exclusive hard link. Identical entries are
idempotent; different files and symlinks retain their contents.

The frontend accepts a single absolute positional file or
`--open-file <file> [--container <path>]`. Requests arriving before the first
bridge catalogue are queued with a 64-item bound and processed once the
catalogue is ready. An explicit prefix selects that registered container,
including when another prefix appears first. File-manager URL delivery and
drag/drop share the same admission path. An unavailable Windows execution
service produces a visible platform message; Wine execution remains within
the user's excluded scope. Linux reveal actions use file-manager labels.

Verification passes 85 shared bridge tests on macOS and ARM Ubuntu Swift
6.0/6.4, plus 12 macOS native-adapter tests and 125 GPUI tests on each platform.
New shared regressions cover idempotence, foreign targets, symlinks, source-byte
preservation, invalid launchers and unregistered prefixes. Startup argument
regressions cover literal paths and malformed handoffs. The real Linux gate
runs `desktop-file-validate` and GIO launches using Unicode, quotes, backslashes,
`%f`, `$HOME` and shell characters. It verifies empty file-code expansion,
MIME handler discovery and preservation of an existing effective default.

The production Xvfb scenario installs the desktop entry through settings,
creates a program shortcut through its settings sheet, and launches that file
through GIO into a second production window. Both the initial cold handoff and
the shortcut select the second registered prefix correctly. It checks metadata,
executable and registry bytes, graceful exit for both windows, and protocol
traces covering installation and shortcut creation. CI retains reports,
generated desktop files, request logs and screenshots.

A complete-gate run also exposed a `/proc` decoding failure from a byte-truncated
UTF-8 process name. Process birth-identity parsing now reads raw bytes and
decodes only the ASCII stat fields; the export process-group verifier tolerates
arbitrary comm bytes. A focused regression supplies an invalid UTF-8 name and
verifies the exact start-time identity.

The subsequent identity and managed-update stages supply stable references
for new shortcuts and upgrade verified legacy path-bound entries.
Local evidence under `build/portability/gui-linux/` includes
`desktop-macos.log`, `desktop-gpui-macos.log`, `desktop-swift60.log`,
`desktop-final-linux.log`, `desktop-process.log`, `desktop-final-window.log`,
`linux-gpui/desktop/` and `linux-gpui/desktop-window/`.

## Stable container references for desktop shortcuts

New Linux shortcuts use `--container-id <UUID>` and a container-relative program
path. The registry stores `whiskyContainerIdentities`, mapping each UUID to its
last known path and directory device/inode identity. Allocation holds an
exclusive registry lease and preserves unknown registry fields. Prefix metadata
and program bytes remain intact. Executables reached through prefix aliases
are normalized into a relative path; external executables retain absolute paths.

Container moves update paths, directory identity and the existing lifecycle
commit marker in one atomic registry write. Same-device and cross-device moves
share this boundary. Recovery before commit restores the original tree and
identity; recovery after commit keeps the new tree and identity. The ID stays
with the original container across duplication. A clone receives its own ID
when a shortcut is created for it. Deregistration retains the ID while resolution
requires a registered matching directory; reimporting the original directory
restores the reference. Physical deletion removes its IDs in the registry commit.
Corrupt identity records stop mutation before tree changes, and replacement
directories receive separate identities.

`system.desktop.resolve` validates the registered directory identity and resolves
the current executable. It rejects relative parent traversal and missing targets.
The frontend resolves IDs after catalogue readiness, retains pending reads across
helper reconnects and ignores superseded replies. The combined pending/admission
queue stays bounded at 64 requests. Legacy absolute `--container` handoffs remain
supported. The following managed-update stage upgrades existing path-bound
entries after verifying their stored executable and container binding.

Verification passes 92 shared bridge tests on macOS and ARM Ubuntu Swift
6.0/6.4, 12 native macOS adapter tests and 126 GPUI tests on each platform.
New regressions cover original/clone identity, directory replacement,
deregistration/reimport/deletion, corrupt stores, both sides of move recovery,
relative-path admission and prefix aliases. The real helper moves one prefix
within its filesystem and into `/dev/shm`, restarts, duplicates, deregisters,
reimports and deletes it. The original desktop file and ID stay byte-for-byte
stable through the moves. The production window creates a shortcut, another
helper moves its prefix, and GIO starts a second production window using the
unchanged shortcut. Its registered prefix selection and source/program data are
verified, and the trace includes `system.desktop.resolve` with Wine execution
outside the active host capability set.

CI's full Linux gate includes `check-shortcut-identity.py` and retains its report
and helper log. The desktop-window scenario now includes relocation before GIO
launch. Local evidence under `build/portability/gui-linux/` includes
`identity-macos.log`, `identity-gpui-macos.log`, `identity-swift60.log`,
`identity-final-linux.log`, `identity-window.log`,
`linux-gpui/shortcut-identity/` and `linux-gpui/desktop-window/`.

## Managed desktop updates and legacy shortcut upgrade

The settings desktop action reports an available update when the stored launch
command differs from the requested frontend path. Installation refreshes an
owned entry after verifying its exact generated Exec command against its stored
launcher. The stored frontend may already have been removed. Shortcut creation
also accepts the verified legacy absolute executable/container pair and upgrades
it to the current frontend, relative executable and stable container UUID.

Updates preserve custom Name/Icon fields, extra keys, comments, action groups,
line endings and permission bits. Main application MIME types merge with the
existing list; `mimeapps.list` contents and effective defaults remain intact.
Edited launch commands, foreign files, symlinks and same-name shortcuts bound
to another program retain their contents and produce a specific conflict error.
Legacy binding verification uses the current container path; a legacy prefix
already moved without a known mapping requires explicit reassociation.

A process-shared per-entry lease serializes status and publication. A bounded
journal records both file identities and payloads before the old entry is
retired to a private sibling. Exclusive publication establishes the commit
boundary. A fresh status/install request recovers an interrupted update:
pre-publication recovery restores the old entry, and post-publication recovery
keeps the new entry, including subsequent in-place edits. A competing target
and its recovery backup are both retained for explicit conflict resolution.
The recovery record lives at `<entry>.whisky-update.plist`.

Verification passes 101 shared bridge tests on macOS and ARM Ubuntu Swift
6.0/6.4; GPUI passes 126 tests on each platform. New regressions exercise four
transaction phases, concurrent edits, malformed journals, program-binding
collisions, legacy upgrade and preservation of customized entries. The real
helper test launches both refreshed entries through GIO, confirms exact new
frontend arguments and kills a live update after observing its journal. The
recorded run observed the pre-publication boundary; a fresh helper restored a
complete old entry, then completed the requested update.

The production Xvfb flow updates a customized old application entry through
settings and upgrades a customized legacy program shortcut. Another helper
moves its prefix, then GIO launches the upgraded shortcut into a second
production window with the correct container selected. Recorded requests stay
within file/host capabilities. CI runs the process and window checks and retains
the journal, reports, helper logs, generated entry and screenshots.

Local evidence under `build/portability/gui-linux/` includes
`desktop-update-macos.log`, `desktop-update-gpui-macos.log`,
`desktop-update-swift60.log`, `desktop-update-final-linux.log`,
`linux-gpui/desktop-update/` and `linux-gpui/desktop-window/`.

## Settings follow the connected helper services

Each connected session publishes its advertised method list to the view model.
Settings use that list to enable desktop installation, terminal detection,
container-directory selection and runtime-specific actions. Exit policy,
post-exit refresh and Wine update preferences become read-only while their
corresponding runtime services are absent. Their stored values remain intact;
supported library settings continue to persist through the shared preference
service. The runtime panel describes the current file/host services when setup
methods are absent, and an unresolved container location shows a loading label.

Disconnect and reconnect replace the method list and clear the previous setup
status. Opening settings and startup query setup status only when it is
advertised. Terminal and desktop queries also check the active session before
sending an optional request. Automatic installer prompts and update checks
follow the same method availability.

The production Xvfb settings scenario uses a test-only advertisement filter
around the real Swift helper. It starts with three host methods omitted,
verifies inert controls and unchanged runtime preferences, and persists a
supported cover-layout preference. It also verifies writable offline mode and
read-only runtime update policy. It terminates the helper child and uses the
production Refresh action to trigger reconnect. The next session advertises
all host methods and installs a real desktop entry through the settings button.
A third session omits those methods again and verifies restored read-only
controls. Request traces verify the exact host methods and preserve the
runtime exclusion throughout this flow. Local evidence includes
`settings-services-macos.log`, `settings-services-final-linux.log`,
`settings-services-network-window.log` and
`linux-gpui/settings-window/` under `build/portability/gui-linux/`.
CI retains the scenario report, screenshots, application log and request trace.

## Relocatable Linux release bundle

`apps/whisky-gpui/tools/build-linux-release.sh` builds the production Rust
frontend and all three SwiftPM executable products in Release mode. SwiftPM
resolution takes place in an isolated source copy, keeping the checkout's
platform-specific lock graph intact. Packaging requires `patchelf`; development
dependency installation includes it. Choose a fresh
`WHISKY_LINUX_RELEASE_OUTPUT` for each artifact set.

The archive contains a `Whisky/` directory with a `Whisky` shell launcher,
`bin/whisky-gpui`, `bin/whisky-bridge`, `bin/whisky-file-picker`,
`bin/whisky-host-command` and the resolved Swift runtime closure under
`lib/swift`. Copied programs use `$ORIGIN/../lib/swift`; copied runtime libraries
use `$ORIGIN`. Both the launcher and the direct frontend binary resolve the
sibling helper after the entire directory moves. Launcher symlinks resolve to
the current bundle location. GTK, graphics drivers, fonts, certificates and
host tools, including GIO from `libglib2.0-bin`, come from the Ubuntu 24.04 packages listed in
`linux-runtime-packages.txt`; `install-linux-runtime-deps.sh` installs that list.

All payloads have explicit archive permissions: directories and program entry
points use `0755`, ordinary files use `0644`. This covers OrbStack shared volumes
whose new-file mode can otherwise be `0666`. Existing artifact paths are
preserved and packaging requires new bundle/archive destinations. The archive
is published by an exclusive hard link after compression finishes.

`manifest.json` records file sizes, modes, SHA-256 hashes, architecture,
compiler versions, original binary/runtime hashes, source commit, dirty-tree
status and the exact application source snapshot hash. The bundle carries
application sources plus the resolved Rust `.crate` source archives, each
checked against `Cargo.lock`, and supplied crate license/notice texts and
manifest declarations. The Swift toolchain license and the full
[upstream ICU 76.1 license and notices](https://github.com/unicode-org/icu/blob/release-76-1/LICENSE)
are preserved. Packaging checks the installed Foundation ICU header against the
available license version. Copied ELF RUNPATH modifications are documented.

The `linux-runtime.Dockerfile` builds a separate Ubuntu 24.04 runtime image and
an acceptance stage with virtual-display tools. The acceptance checker requires
an ordinary user and verifies that Swift/Cargo and the source/build workspace
are absent. Its container runs with network disabled. It safely unpacks the
archive, validates all payloads, starts both entry points with helper/runtime
overrides cleared, moves the whole bundle to a Unicode path containing quotes,
spaces, shell characters and `%f`, then launches through an external symlink.
ELF dependency resolution must point into the moved Swift library directory.
An intentional payload edit verifies manifest rejection before fixture repair.

The same checker runs the packaged native picker modes, settings service
reconnects, desktop upgrade/GIO second-window handoff and real interactive
terminal flow, then checks that bundle files retain their original contents.
The settings test helper publishes its child PID by atomic replacement so
reconnect observation sees complete records on both shared and native volumes.
CI uploads the release archive and passes it to a separate clean-runtime job;
that job retains reports, logs, request traces, generated entries and screenshots.
The download step follows the
[official artifact action usage](https://github.com/actions/download-artifact#usage).

Build and check on Ubuntu 24.04:

```sh
WHISKY_LINUX_RELEASE_OUTPUT="$PWD/build/linux-release-run" \
  bash apps/whisky-gpui/tools/build-linux-release.sh
docker build --target acceptance -t whisky-package-acceptance \
  -f apps/whisky-gpui/tools/linux-runtime.Dockerfile apps/whisky-gpui/tools
docker run --name whisky-package-acceptance --network none \
  --mount "type=bind,src=$PWD/build/linux-release-run/whisky-linux-$(uname -m).tar.gz,dst=/archive.tar.gz,readonly" \
  --mount "type=bind,src=$PWD/apps/whisky-gpui/tools,dst=/tests,readonly" \
  whisky-package-acceptance python3 /tests/check-linux-package.py \
    --archive /archive.tar.gz --output /evidence --gui
docker cp whisky-package-acceptance:/evidence build/linux-package-evidence
```

Local artifacts live under `build/portability/gui-linux/linux-release/`.
Evidence includes `package-release-build.log`, `package-distribution-build.log`,
`package-runtime-image-final.log`, `package-runtime-complete-build.log` and
`package-runtime-complete-check.log`. The final ARM64 run passes all 13 checks
in 60.14 seconds as UID 10001 with network disabled. Its complete evidence is
under `package-runtime-verified/`, including the root report, picker report,
three production-window reports, request traces and screenshots. The tested
archive is `linux-release/whisky-linux-aarch64-runtime-complete.tar.gz`, SHA-256
`b4d513173dbd638bb472bd11a3214bc20fac062a9b96e9a2738d654be4b5e1d7`.
It contains four executable products, 16 Swift libraries, 557 locked Rust source
archives and 1,486 manifest payloads. Application binaries were compiled from
`95ae744`; the manifest records the local packaging-tool work as a dirty source
tree and hashes the corresponding source snapshot. Existing-output and invalid
ELF checks also pass, with evidence in `package-input-check.log` and
`linux-release/input-validation.json`.

The local gate proves ARM64 Ubuntu 24.04/X11 software-rendered operation.
The x86_64 hosted job is configured and awaits its first remote run; additional
distributions and Wayland remain in the desktop acceptance matrix.

## Shared GameDB identities and platform reference review

The canonical 83-game/86-variant database now lives in
`WhiskyCore/Sources/WhiskyCore/Resources/GameDB.json`. WhiskyCore owns the
Foundation-only identity scorer, executable metadata/fingerprint types and
match tiers. Steam IDs, size/timestamp fingerprints, case-insensitive executable
names, path confirmation, generic-name penalties, fuzzy tokens, ambiguity and
alias search share one implementation. WhiskyKit preserves its existing public
names through aliases and adapts shared scores back into native `MatchResult`
values; its existing machine-specific variant selector and application flow
continue to serve native callers.

The portable `gameConfig.match` service advertises `gameConfig.read`. It reads
registered catalogue entries under the existing shared workspace lease, honors
pending lifecycle recovery, returns the original source record and up to three
matches, and preserves every container file. The current corpus has 81 games
with explicit macOS minimum-version constraints. Portable replies therefore
identify the source platform as macOS and carry `canApply: false`, the minimum
OS context and source settings/components for reference. This reports game
identity confidence and source compatibility evidence as distinct fields.
`gameConfig.apply` continues to depend on the platform/runtime adapter;
Linux runtime distribution follows the [Wine update contract](LINUX_WINE_UPDATES.md);
applying this macOS reference corpus has its own platform/runtime gate.

The GPUI sheet shows source-platform labels, reference settings and a read-only
reference action in file-only sessions. Both the view model and supervisor
check the connected application capability; a per-match eligibility field adds
the source-specific constraint. Older native payloads keep their existing
behavior when the method is advertised. A database failure has a separate,
entry-scoped completion event and a retry control. Restoring the resource and
clicking Retry re-reads it; a retained pending sheet can also resume after
helper reconnection. These states preserve ordinary metadata search/apply UI.

SwiftPM bundles the canonical resource with WhiskyCore. The resource locator
covers flat Linux `.resources`, macOS `.bundle/Contents/Resources`, application
resource folders and XCTest's module bundle. Missing and malformed resources
produce recoverable `database_unavailable` replies in the portable service.
Database schema version, unique/nonempty IDs and the 8 MiB bound are validated.
Both Linux and macOS GPUI packagers now copy the shared resource bundle.

Verification passes 116 core tests and 103 portable bridge tests on macOS and
ARM Ubuntu Swift 6.0/6.4, plus 12 native bridge tests. WhiskyKit's original
32 XCTest and two DirectX-12 GameDB regressions pass. Both GPUI platforms pass
127 tests. New regressions cover scoring, ambiguity, moved resources, malformed
records, source-byte preservation, application refusal and pending recovery.
The real helper gate checks restart, resource relocation, missing/corrupt data,
repair and continued session use. The production window opens the canonical
AoE2 reference, clicks the disabled reference action, retains all original
container/registry bytes, shows a completed resource error, restores the file
and retries through the visible control. Request traces stay within file/host
capabilities. CI runs the process/window checks and retains both directions of
the test protocol trace. The clean release checker includes this window flow.

Local evidence under `build/portability/gui-linux/` includes
`gamedb-core-macos.log`, `gamedb-bridge-macos.log`,
`gamedb-final-reference-macos.log`, `gamedb-kit-macos.log`,
`gamedb-gpui-macos.log`, `gamedb-full-linux.log`, `gamedb-swift60-final.log`,
`gamedb-final-window.log`, `gamedb-lint.log`, `linux-gpui/gamedb/` and
`linux-gpui/gamedb-window/`.

The Release artifact was built from clean commit `fa5b836`. Its manifest has
`sourceTreeDirty: false` and preserves the canonical JSON hash
`32611509865fdd4b8e4e832293e4a230da7a4924040c9e0c8ef87e6acfc9ba2a`.
The independent Ubuntu 24.04 acceptance container runs as UID 10001 with network
disabled, Swift/Cargo and the build workspace absent. All 14 checks pass in
73.34 seconds, covering launcher/direct entry points, moved library/resource
resolution, payload integrity, pickers, settings reconnect, GIO desktop startup,
interactive terminal and the GameDB reference/error/retry flow. Final payload
hashes remain unchanged after the complete run. Evidence is
`gamedb-release-build.log`, `gamedb-clean-runtime.log`,
`gamedb-runtime-container.json` and `gamedb-runtime-verified/`.
The verified archive is `gamedb-release/whisky-linux-aarch64.tar.gz`, SHA-256
`a6074e138018ba51460d86ac645da79aa36cde2c5e07f12f23395bf6fed24176`.

Targeted strict lint passes the new shared sources, native adapters, protocol
accessor and focused tests. The broad `Service.swift` lint retains its existing
file-length, library-dispatch complexity and line-length findings; the new
GameDB dispatch is factored into its own method. macOS application packaging
copies the new resource bundle; this stage's native evidence is package/API
compilation and tests. ARM64 Linux provides the complete clean Release/window
evidence; hosted x86_64 and Wayland acceptance remain separate gates.

## Native Wayland and session-aware terminal stage

The production Linux window now publishes `com.franke.Whisky` as its Wayland
application ID, matching the installed desktop entry. Linux terminal discovery
filters XTerm/UXTerm and Foot by the active display protocol. Pure Wayland
sessions prefer Foot, followed by GNOME Terminal and other available wrappers;
X11 retains its existing preference order. The settings selector persists Foot
with the existing Linux terminal preference key.

The GTK chooser opens the nearest existing parent when its initial path contains
directories awaiting creation. Existing files retain selection and save dialogs
retain the requested filename. A real X11 chooser regression selects a directory
from a missing nested initial path and verifies that those directories remain
uncreated. The production Wayland settings flow exercises the same first-use
case through the actual bridge and GTK helper.

`tools/smoke-wayland.py` starts unprivileged headless Sway with Pixman, a native
1280×900 output, persistent virtual keyboard/pointer devices and clipboard
transfer. Its configuration disables Xwayland; each observed application,
chooser and Foot window must use `xdg_shell`, and Whisky windows must have the
stable application ID and a null X11 window identifier. Protocol XML provenance
and embedded licenses are preserved in `tools/wayland-input/README.md` and the
adjacent source files. The test input helper is built in a separate Docker stage.

ARM64 Ubuntu 24.04 completed nine real production-window flows: preference
keyboard/pointer writes, desktop-entry identity, native GTK directory selection,
Unicode clipboard argument save with unknown-settings preservation, GIO shortcut
startup and graceful secondary-window exit, Foot with an interactive PTY,
source-file preservation with explicit stable identity allocation, and primary
quit/restart persistence. The compositor tree, screenshots, bridge requests,
responses and PTY probe are retained under
`build/portability/gui-linux/wayland-endtoend-evidence/`. Both the frontend and
helper use isolated registry, XDG and source-prefix fixtures.

Linux regression completed Core 116, Metadata 20, Bridge 104 and Rust 127 tests,
plus the existing program/metadata/lifecycle/recovery/import/diagnostic/desktop/
GameDB process checks. Native macOS targeted terminal tests pass 5/5; native Rust
passes 127/127. The clean X11 runtime archive regression passes all 14 checks,
including native chooser, settings, desktop, terminal and GameDB windows.

The release checker accepts `--wayland`, verifies/extracts the manifest, relocates
the bundle into a literal Unicode/special-character path, then drives the native
session and verifies final payload integrity. CI runs the same release artifact
through separate X11 and Wayland runtime jobs with UID 10001 and network disabled.
Hosted x86_64 results and additional desktop/distribution environments remain
separate acceptance gates.
Targeted strict Swift lint and patch whitespace checks pass. The repository-wide
Rust formatting check reports existing differences in unchanged modules; this
stage preserves the surrounding source style.

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
| Program settings and history | Complete shared file services, native-model compatibility, concurrent real helpers and seeded UI writes/reload | Linux .desktop creation and GIO startup verified; broader UI override editing remains in the desktop gate |
| Metadata and covers | Shared metadata services; live provider search; seeded UI artwork operations; shared GameDB identities and explicit macOS reference review with recovery/retry | Broader seeded search/apply interactions; Linux runtime configuration has separate acceptance |
| Container lifecycle | Linux lifecycle, routes, discovery/import and export SIGKILL recovery; complete production file-lifecycle window flow, recovery and candidate import UI | Additional platform coverage follows the desktop acceptance matrix |
| Host integration | XDG preferences; file open/reveal; GTK dialogs; real terminal/window acceptance; managed desktop updates, legacy shortcut upgrade and stable relocation | Additional terminal/desktop environments; settings now follow connected helper services |
| Diagnostics | Native macOS adapter; Linux bounded host/file report, platform checks, exclusive export and production-window acceptance | Additional desktop platform coverage follows the acceptance matrix |
| Distribution | macOS `.app` packaging; ARM64 Linux Release archive with Swift libraries, native helpers, source/license evidence and unprivileged clean-Ubuntu CLI/window acceptance | First x86_64 hosted archive/runtime run and additional distributions |
| Desktop acceptance | ARM64 X11 and native headless Wayland; real GTK chooser, clipboard, GIO shortcut, Foot PTY and restart persistence | Broader seeded interactions and desktop environments; x86_64 hosted CI evidence |

Wine download and update tasks follow the dedicated runtime contract. Windows
process execution and game compatibility have separate acceptance evidence.
File editing and host integration remain part of the Linux adaptation target.
