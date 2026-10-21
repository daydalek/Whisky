# whisky-gpui

Tracked GPUI app for the Whisky desktop UI. This is the M0 seed: the sources were
copied mechanically from the local design demo at `demos/gpui-demo/`, which is
gitignored and not part of the repository. The demo remains the visual reference.

At this stage the app renders 32 hard-coded games with in-memory state. It does
not start Wine, scan real containers, or talk to `whisky-bridge` yet. Later
milestones replace the sample data with bridge-backed data; see
[`docs/gpui-port/PLAN.md`](../../docs/gpui-port/PLAN.md).

## Layout

- `src/main.rs` — window, app state, library and settings surfaces.
- `src/preview.rs` — page and sheet mockups for the bottle/program/configuration screens.
- `src/games.rs` — sample library data.
- `src/library_layout.rs` — cover grid geometry.
- `src/motion_capture.rs` — `visual-test`-only scroll and motion measurements.
- `assets/` — covers and pre-blurred backgrounds.

The module layout is intentionally unchanged from the demo. Splitting it into
domain modules is milestone M1.

## Build and test

Network access is not required; the lockfile resolves against the local cargo
registry.

```sh
env RUSTC_WRAPPER= cargo build --offline --locked --manifest-path apps/whisky-gpui/Cargo.toml
env RUSTC_WRAPPER= cargo test  --offline --locked --manifest-path apps/whisky-gpui/Cargo.toml
```

The binary is `apps/whisky-gpui/target/debug/whisky-gpui`.

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
