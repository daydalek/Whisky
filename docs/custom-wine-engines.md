# Custom Wine engines (macOS)

Maltoria's macOS GPUI app can run individual bottles on a locally installed,
external Wine runtime instead of the managed Whisky Wine build. Engines are
registered once in Settings and then bound per bottle; the managed runtime
stays the default and is never silently replaced.

This applies to macOS only. Linux keeps the existing managed-runtime flow and
the `--wine-runtime` / `WHISKY_WINE_RUNTIME` override unchanged.

## Accepted engine layouts

Detection is static — nothing in the tree is ever executed to register it.
Two layouts are accepted:

- **Standard root**: the directory itself contains `bin/` and `lib/`.
- **Nested `Wine/`**: the directory contains a `Wine/` subdirectory with
  `bin/`/`lib/` inside; payload directories (DXVK, DXMT, D3DMetal,
  GDICoreML) found next to `Wine/` or inside it are detected as features.

Required inside the effective root:

- `bin/wine64` (preferred) or `bin/wine` — an executable Mach-O with at least
  one `arm64` or `x86_64` slice.
- `bin/wineserver` — executable Mach-O sharing at least one architecture
  slice with the loader.
- `lib/` — a directory (may be empty).

Registration rejects, with a visible reason:

- Missing root, loader, server, or `lib/` directory.
- Non-executable files, shell scripts, or wrappers in place of the loader —
  scripts are never run or wrapped.
- Non-Mach-O binaries (ELF, truncated files), `i386`-only binaries, and
  loader/server pairs with no common architecture.
- Anything found by searching inside `.app` bundles — there is no recursive
  search; the directory must be the engine root itself.

Paths with spaces, Unicode, and quotes are fine. Symlinked roots are resolved
to their canonical path, and registering the same root twice reuses the
existing registration rather than duplicating it.

The registry lives at
`~/Library/Application Support/<bundle id>/Wine Engines.json` and is shared
by the app, the bridge helper, and the CLI. A missing registry means "no
external engines"; a corrupt one is reported to the UI instead of silently
dropping entries.

## Per-bottle lifecycle

- **New bottles**: the creation dialog offers the registered engines. The
  engine is resolved and validated *before* the prefix directory or any
  filesystem state is created, then stored in the bottle's settings.
- **Existing bottles**: bottles saved before this feature default to the
  managed engine. The Bottle page shows the bound engine and lets you rebind
  — a confirmation warns that the existing prefix is *not* converted for you.
- **Rebinding is refused while the bottle is busy** — launching, running, or
  in an indeterminate process state. A failed rebind leaves the previous
  binding untouched.
- **A missing or broken engine does not fall back to managed.** The bottle
  page keeps the selection readable so you can rebind it, but launching
  fails explicitly until you do.
- **Removing a registration** requires that no registered bottle still
  references it. Removal only forgets the registration — it never deletes
  files from your engine tree. The managed row cannot be removed.

## Read-only ownership

External engine trees are treated as read-only:

- No updates, no payload deployment: GPTK/D3DMetal, DXVK, DXMT and the GDI
  upscaler are never written into an external tree.
- No borrowing: an external launch never loads libraries or payloads out of
  the managed runtime, and managed-runtime compatibility fixes are disabled
  rather than applied.
- The wineserver probe and all bottle operations use the external tree's own
  binaries.

Conversely, the managed runtime remains managed-only: install, update, and
GPTK import always target the managed tree regardless of any bottle's
selection.

## Capability status and confirmation

Every engine reports a per-feature status that drives both the UI and the
launch environment:

- **Supported** — the managed runtime's proven capabilities. External trees
  never get this level: a detected payload (e.g. a `DXVK/` directory with
  the expected DLLs) proves the files are there, not that they work.
- **Unverified** — the physical prerequisites are complete but compatibility
  is not proven: payload-bearing features (DXVK, DXMT, D3DMetal, CoreML
  upscaling — files alone cannot show that Wine picks up the patches they
  need) and everything detection cannot see at all (esync/msync, AVX, Metal
  options, DXVK async, frame generation, etc.). Disabled by default; shown
  with its reason plus an explicit "confirm, then enable" action.
- **Unavailable** — a mandatory prerequisite is missing (no DXVK payload,
  incomplete DXMT set, dead loader). Cannot be enabled at all; confirmation
  cannot bypass it. Features with hard dependencies stay unavailable until
  the parent is approved too — approving D3DMetal alone does not unlock
  MetalFX, which needs its own confirmation.

Confirmations are persisted per bottle as *feature → engine fingerprint*
pairs:

- Enabling an unverified feature requires confirming against the engine's
  **current** fingerprint. Approving `msync` does not approve anything else.
- The fingerprint is derived from the canonical root plus loader/server and
  library/payload marker metadata (relative paths, sizes, mtimes). Replacing
  or rebuilding the engine — including a library-only update — changes it
  and every approval bound to the old fingerprint stops applying; the UI
  asks again. (The fingerprint is metadata-based, not a content hash of the
  whole tree: it is a change detector, not an integrity proof.)
- **Revoke is explicit.** Turning a setting *off* just changes the value —
  the approval stays. The engine section on the Bottle page lists every
  enabled approval with a **revoke** control; revoking removes the
  approval, after which every setting that needs it goes back to disabled.
- A stale or rejected confirmation applies *no* configuration write: the
  queued change only lands after the helper replies with the approval
  persisted under the same fingerprint it was requested for.

## Concurrency scope

Every Wine operation — prefix creation, launches, Winetricks, registry
imports, wineserver queries — holds a **shared** engine lease on the
prefix and pins one engine descriptor plus the approval snapshot for the
whole call, including nested work. Rebinding an engine or mutating feature
approvals takes an **exclusive** lease, checks the bottle is idle
(in-process busy state plus a wineserver probe that fails closed on
error), and only then writes. The lock files live inside Maltoria's own
registry directory — nothing is ever written into an external engine tree
or a bottle prefix.

The mutual exclusion covers Maltoria processes only (GPUI app, bridge
helper, CLI). A Wine instance started outside Maltoria holds no lease; if
the bound engine is missing entirely, recovery additionally requires a
host-wide check that no wineserver is running before the bottle can be
rebound.

Policy is enforced twice: the UI disables the field (or the individual
choice) with a reason, and the launch environment re-checks the same gate.
A saved setting that requests a gated feature is left in place but not
honored — e.g. a bottle saved with the DXVK backend launches on base
WineD3D on an engine without a DXVK payload, and no DXVK DLL overrides or
`DXVK_*` variables are injected. Launcher profiles that require DXVK are
gated the same way.

External engines get a `.recommended` backend of base WineD3D unless a
capability is actually present or confirmed — never a managed default like
DXVK.

## Setup with only external engines

The managed runtime is optional once at least one usable external engine is
registered: `setup.status` reports `managedInstalled` and
`anyEngineAvailable` separately, and onboarding does not force the managed
install when an external engine can run bottles. Limitations:

- Managed-runtime compatibility fixes and the managed GDI upscaler payload
  do not apply to external bottles.
- Wine version reporting reflects what the external loader reports; a
  version that cannot be probed is shown as unknown rather than invented.
- Removing the last usable external engine while bottles are bound to it is
  refused until they are rebound; an unregistered-but-still-bound engine
  leaves the bottle on a broken selection (visible, with a reason) until
  you pick another engine.
