# whisky-gpui

Tracked GPUI app for the Whisky desktop UI. This is the M0 seed: the sources were
copied mechanically from the local design demo at `demos/gpui-demo/`, which is
gitignored and not part of the repository. The demo remains the visual reference.

At this stage the app renders 32 hard-coded games with in-memory state. M1a
adds a live `whisky-bridge` connection (handshake plus one container-catalogue
read) but still renders `model::demo_data()`; real library data arrives in M1b.
The bridge never starts Wine or mutates a container in this milestone. Later
milestones replace the sample data with bridge-backed data; see
[`docs/gpui-port/PLAN.md`](../../docs/gpui-port/PLAN.md).

## Layout

- `src/main.rs` — app entry, window options, root view composition, capture hook.
- `src/theme.rs` — colours and animation durations shared by every surface.
- `src/model.rs` — `Game` plus the demo library snapshot until M1b.
- `src/state.rs` — `WhiskyApp`, page/sheet enums, navigation, filtering and sorting.
- `src/controls.rs` — shared widgets (rows, icons, badges, round buttons).
- `src/views/` — library, bottle, settings, and dialog surfaces.
- `src/library_layout.rs` — cover grid geometry.
- `src/motion_capture.rs` — `visual-test`-only scroll and motion measurements.
- `assets/` — covers and pre-blurred backgrounds.

`src/games.rs` and `src/preview.rs` from M0 were split into these modules without
changing any constant, layout, or copy.

## Build and test

Network access is not required; the lockfile resolves against the local cargo
registry.

```sh
env RUSTC_WRAPPER= cargo build --offline --locked --manifest-path apps/whisky-gpui/Cargo.toml
env RUSTC_WRAPPER= cargo test  --offline --locked --manifest-path apps/whisky-gpui/Cargo.toml
```

The binary is `apps/whisky-gpui/target/debug/whisky-gpui`.

## Bridge helper

The helper is the SwiftPM executable product `whisky-bridge` from
`WhiskyBridge/Package.swift`:

```sh
swift build --package-path WhiskyBridge -c release
```

The app resolves it in this order and uses the first regular file:

1. `WHISKY_BRIDGE_HELPER` — must be an absolute path; if set but missing, the
   app reports that path instead of falling through.
2. `whisky-bridge` next to the running executable.
3. `Contents/Resources/whisky-bridge` below the executable, plus the standard
   `.app` layout (`../Resources/whisky-bridge`) for future bundling.
4. `<repo>/WhiskyBridge/.build/release/whisky-bridge`, then
   `…/.build/debug/whisky-bridge`. The repo root is found by walking up from
   `CARGO_MANIFEST_DIR` until a directory contains `WhiskyBridge/Package.swift`.

`PATH` is deliberately not consulted. If nothing is found the UI shows
`Unavailable`; the supervisor retries with capped exponential backoff
(0.5 s → 8 s) and the status dialog offers an immediate `Retry`.

The bridge's container method is `workspace.containers` (the plan's
`containers.list` name does not exist in `ApplicationService.methods`). M1a
calls it once after the `bridge.describe` handshake and logs the count and names
to stderr.

To exercise the connection without opening a window:

```sh
apps/whisky-gpui/target/debug/whisky-gpui --print-bridge-status
```

This prints the `bridge.describe` payload as JSON and exits 0; helper
resolution, handshake, allow-list, or container-call failures print to stderr
and exit 1.

## Visual baseline capture

Build with the `visual-test` feature and set `WHISKY_DEMO_CAPTURE`. PNGs are
written to `screenshots/` inside the crate and exit the process when done.

```sh
env RUSTC_WRAPPER= cargo build --offline --locked --features visual-test \
  --manifest-path apps/whisky-gpui/Cargo.toml
WHISKY_DEMO_CAPTURE=1 apps/whisky-gpui/target/debug/whisky-gpui
```

Keep the captured reference set local; do not commit it.
Recapture and compare when a visual change is intended.

## Tools

- `tools/generate_covers.py` — regenerates the original procedural cover art
  (requires Pillow and NumPy). The bundled design snapshot uses these covers.

The demo's `tools/package_motion_review.py` was not copied: it hardcodes the demo
directory and the `whisky-gpui-demo` binary name. Packaging is handled in M6.
