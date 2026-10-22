# GPUI port plan

Status: M2 complete; M3 bottle creation and winetricks are wired. Full
ProgramSettings and `entry.move` remain the open M3 items. This document
tracks remaining work against the live `apps/whisky-gpui/` tree (ahead of the
M1-only checklist that previously lived here).

## Goal

Ship a GPUI app that is functionally at parity with `/Whisky` and visually
aligned with `demos/gpui-demo`, running on the portable `whisky-bridge` base.
macOS keeps the SwiftUI app as a first-class frontend; GPUI is the Linux path
and a parallel macOS client. SwiftUI is not removed at M6 — packaging adds the
GPUI product alongside it.

## Architecture

- GPUI (Rust) is the UI process.
- It spawns `whisky-bridge` (Swift helper) as a child process over NDJSON on
  stdio and performs a `bridge.describe` handshake before showing data.
- On macOS the helper is started with `--enable-wine` so Wine host effects
  (`bottle.create`, configuration side effects, process kill) are available.
  Set `WHISKY_BRIDGE_NO_WINE=1` to opt out.
- All mutations go through `whisky-bridge::Client`; the UI does not read or
  write container files directly.
- The bridge helper is a separate process; a failed call or crashed helper must
  be observable and recoverable from the UI.

## Non-negotiables

- Every commit compiles and runs.
- The app never panics on bridge failure; it degrades to an error surface with a
  retry path.
- `cargo build --offline --locked` and `cargo test` pass for `apps/whisky-gpui`.

## Milestones

- [x] **M0** seed tracked app
- [x] **M1** bridge supervisor + typed DTOs; real containers + library read-only
- [x] **M2** library interactions: layouts, search, sort, hide, rating, detail,
      launch/stop, clipboard preflight, runtime events, refresh, reveal, open C
      drive, folder executable picker
  - Remaining M2 notes: activity write APIs beyond rating are tracker side
    effects + library reload; `entry.move` deferred to M3 gap table
- [ ] **M3** bottle surfaces
  - [x] schema-driven configuration, folder scan jobs, programs, processes,
        environment
  - [x] create bottle (bridge job with refreshed catalogue)
  - [x] winetricks list/install (catalog + installed reads, headless install
        job with progress, cancel and per-verb results)
  - [ ] full ProgramSettings (args, locale, DLL overrides, shortcuts, history)
  - [ ] `entry.move`
- [ ] **M4** application settings, localization, native menus, menu-bar extra,
      about, file-open/drag-drop, window restore
- [ ] **M5** remaining parity: metadata search/attach, DLL overrides, shortcuts,
      audio, diagnostics/troubleshooting, steam, bottle migration/import/rename/
      delete, updater
- [ ] **M6** packaging (.app bundle, icon, codesign, CI job) for the GPUI
      product alongside SwiftUI

## Bridge gap table

These methods are not exposed by `whisky-bridge` yet (or not wired in GPUI).
Each entry names the Swift type whose JSON encoding the bridge needs; method
names are proposals and must also be added to `ApplicationService.methods`
when new.

| Gap | Swift type to encode | Target | Notes |
| --- | --- | --- | --- |
| Metadata search, attach, detach, custom cover | `GameMetadata`, … | M5 | |
| Bottle rename, import, delete, copy, migrate, scan orphans | `BottleSettings`, registry | M5 | `bottle.create` exists (native, `--enable-wine`) |
| Move a library entry to another bottle | New `entry.move` | M3 | |
| Full `ProgramSettings` | `ProgramSettings`, … | M3 | Run-settings sheet is still demo |
| Activity write side beyond rating | `GameActivity`, … | M2 note | Rating write done; play time via tracker |
| Steam download snapshot and subscribe | `SteamDownloadSnapshot`, … | M5 | |
| Diagnostics report, log, fixes | `TroubleshootingSession`, … | M5 | |
| Audio device enumeration, test tone | `AudioDeviceInfo`, … | M5 | |
| Expanded preferences keys | `PreferencesService` schema | M4 | |
| Shortcut creation | `ProgramShortcut` | M5 | |

## Known constraints

- No push channel. `runtime.events` is a cursor poll over a 128-event ring, so
  the UI must tolerate drops and gaps.
- The protocol caps a frame at 1 MiB.
- A call timeout is session-fatal. The client must be restartable without
  restarting the UI process.
- `ApplicationService.methods` is hand-maintained. A new method must be added
  there or the Rust allow-list check rejects it.
- Winetricks resolves `winetricks`, `verbs.txt` and `cabextract` beside the
  helper. `winetricks.installed` may spend up to 30 s in `list-installed`, so
  that one read uses a 45 s call timeout and occupies the worker until it
  finishes; catalog reads and install-job polls stay on the default timeout.
- Winetricks methods are advertised only by the macOS helper with
  `--enable-wine`; the Linux helper has no Wine runtime in M3 and the sheet
  surfaces the helper's `method_unavailable` reply instead of faking success.
- Visual acceptance uses a locally captured baseline (not committed), captured with the
  `visual-test` feature and `WHISKY_DEMO_CAPTURE`.
