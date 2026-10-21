# GPUI port plan

Status: M0 complete (`apps/whisky-gpui/` seeded). This document is the working
checklist for the remaining milestones.

## Goal

Replace the SwiftUI app with a GPUI app that is functionally at parity with
`/Whisky` and visually aligned with `demos/gpui-demo`, running on the portable
`whisky-bridge` base.

## Architecture

- GPUI (Rust) is the only UI process.
- It spawns `whisky-bridge` (Swift helper) as a child process over NDJSON on
  stdio and performs a `bridge.describe` handshake before showing data.
- All mutations go through `whisky-bridge::Client`; the UI does not read or
  write container files directly.
- No SwiftUI at runtime. The SwiftUI target remains in the tree, untouched,
  until M7.
- The bridge helper is a separate process; a failed call or crashed helper must
  be observable and recoverable from the UI.

## Non-negotiables

- Every commit compiles and runs.
- The app never panics on bridge failure; it degrades to an error surface with a
  retry path.
- `cargo build --offline --locked` and `cargo test` pass for `apps/whisky-gpui`.

## Milestones

- [x] **M0** seed tracked app (this commit)
- [ ] **M1** bridge supervisor + typed DTOs; real containers + library read-only
- [ ] **M2** library interactions: layouts, search, sort, hide, move, rating, detail, launch/stop, clipboard preflight, runtime events
- [ ] **M3** bottle surfaces: schema-driven configuration, folder scan jobs, programs, processes, environment, create bottle, winetricks
- [ ] **M4** application settings, localization, native menus, menu-bar extra, about, file-open/drag-drop, window restore
- [ ] **M5** remaining parity: metadata search/attach, DLL overrides, shortcuts, audio, diagnostics/troubleshooting, steam, bottle migration/import/rename/delete, updater
- [ ] **M6** packaging (.app bundle, icon, codesign, CI job) and removal of SwiftUI target from the default build

## Bridge gap table

These methods are not exposed by `whisky-bridge` yet. Each entry names the
Swift type whose JSON encoding the bridge needs; method names are proposals and
must also be added to `ApplicationService.methods`.

| Gap | Swift type to encode | Target |
| --- | --- | --- |
| Metadata search, attach, detach, custom cover | `GameMetadata`, `GameMetadataSearchResult`, `GameMetadataAutomaticMatchOutcome` | M5 |
| Bottle rename, import, delete, copy, migrate, scan orphans | `BottleSettings`, bottle registry records (`BottleVM.plist`) | M5 |
| Full `ProgramSettings`: arguments, locale, DLL overrides, override groups, shortcuts, console/run history | `ProgramSettings`, `ProgramOverrides`, `Locales` | M3 |
| Activity write side: play time, last played, session start/stop | `GameActivity`, `GameActivitySampleToken`, `GameActivityRecordResult` | M2 |
| Steam download snapshot and subscribe | `SteamDownloadSnapshot`, `SteamAppManifest`, `SteamLibrary` | M5 |
| Diagnostics report, log, fixes | `TroubleshootingSession`, `CheckResult`, `FixAttempt`, `TroubleshootingHistoryEntry` | M5 |
| Audio device enumeration, test tone, findings | `AudioDeviceInfo`, `AudioProbeResult`, `AudioFinding`, `AudioDeviceHistory` | M5 |
| Winetricks verbs and install | `WinetricksVerb`, `WinetricksVerbCache` | M3 |
| Expanded preferences keys | `PreferencesService` schema entries | M4 |
| Processes | `WineProcess` (the existing `processes.list` returns untyped JSON) | M3 |
| Shortcut creation | `ProgramShortcut` | M5 |

## Known constraints

- No push channel. `runtime.events` is a cursor poll over a 128-event ring, so
  the UI must tolerate drops and gaps.
- The protocol caps a frame at 1 MiB.
- A call timeout is session-fatal. The client must be restartable without
  restarting the UI process.
- `ApplicationService.methods` is hand-maintained. A new method must be added
  there or the Rust allow-list check rejects it.
- Visual acceptance uses a locally captured baseline (not committed), captured with the
  `visual-test` feature and `WHISKY_DEMO_CAPTURE`.
