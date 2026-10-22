# Linux adaptation and headless verification

The Linux product path is `apps/whisky-gpui` plus the Swift `whisky-bridge`
child process. The active target covers the application's Linux functionality
with Wine execution excluded. Work continues through the remaining services
and distribution gates below.

## Verified on 2026-10-23

OrbStack ARM64 Ubuntu 24.04, Swift 6.4, Rust 1.99.1, Xvfb/X11 and Mesa software
rendering:

- Shared core: 112 tests; portable bridge: 36 tests.
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
`linux-gpui/program-window/`. The two window scenarios run in the Linux CI job.

The keyboard pass found a missing root focus path. The root view now owns a
focus handle, allowing actions to bubble from child text fields as well as
the initially focused root. Linux uses Ctrl shortcuts; macOS retains Command.

Local logs and screenshots are under `build/portability/gui-linux/`:
`gpui-check.log`, `bridge-macos-test.log`, `gpui-macos-test.log`, and
`linux-gpui/window/{report.json,library.png,settings.png,sidebar-toggled.png}`.
The tracked scripts and CI job reproduce the checks; hosted CI execution
requires an actual workflow run.

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
| Library and configuration | Shared storage tests; empty production window and CLI | Seeded-library window edits, folder pickers, persisted ratings/visibility and refresh/recovery |
| Program settings and history | Complete shared file services, native-model compatibility, concurrent real helpers and seeded UI writes/reload | Linux shortcut creation is tracked under host integration; broader UI override editing remains in the desktop gate |
| Metadata and covers | GPUI surfaces call macOS native bridge methods | Extract provider/storage operations and validate search, attach/detach and custom covers on Linux |
| Container lifecycle | macOS native bridge implements rename/remove/move/duplicate/export | Portable lifecycle, import/orphan scan and filesystem acceptance on isolated fixtures |
| Host integration | XDG registry/preferences; file open/reveal adapter | Terminal discovery, desktop/file associations, dialogs and capability-aware settings |
| Diagnostics | macOS report/check adapter | Linux host information, file export and appropriate platform checks |
| Distribution | macOS `.app` packaging | Linux relocatable bundle, Swift runtime libraries, launcher/desktop entry and clean-environment acceptance |
| Desktop acceptance | ARM64 X11 virtual display with Mesa | Seeded end-to-end interactions, restart/recovery and Wayland coverage; x86_64 hosted CI evidence |

Wine installation, Windows process execution and game compatibility follow the
user's explicit scope exclusion. File editing and host integration remain part
of the Linux adaptation target.
