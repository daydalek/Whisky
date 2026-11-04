# How to Contribute

Thanks for your interest! First, make a fork of Whisky, create a new branch for your changes, and get coding!

## Build Environment

CI builds on `macos-26` runners using the runner's `latest-stable` Xcode (see `XCODE_VERSION` in `.github/workflows/CI.yml`). The bundled Wine runtime requires **macOS 27 or later** at run time (see [README](README.md#系统要求-system-requirements)). To build:

- **Swift toolchain** — the one shipped with the CI Xcode release; all Swift dependencies come through Swift Package Manager.
- **Rust ≥ 1.89** — `apps/whisky-gpui` uses file locking from the Rust standard library. Install via [rustup](https://rustup.rs/).
- **Python 3.9+** — `build.sh` and the packaging scripts under `scripts/distribution/` are Python.
- **SwiftLint** — enforced with `--strict` in CI (`norio-nomura/action-swiftlint`).
- **SwiftFormat 0.58.7** — see below for the pin.

Run `./build.sh list` for the full target menu and [docs/BUILDING.md](docs/BUILDING.md) (中文) for the detailed build guide.

## Code Style

### Linting with SwiftLint

Every Whisky commit is automatically linted using SwiftLint. You can run these checks locally by building in Xcode; violations will appear as errors or warnings. For your pull request to be merged, you must meet all requirements outlined by SwiftLint and have no violations.

### Formatting with SwiftFormat

We use [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) to maintain consistent code formatting. This is enforced in CI alongside SwiftLint.

**Required Version: 0.58.7**

Using a different version may produce different formatting results. CI uses this exact version.

#### Installation

**Option 1: Homebrew (latest version)**
```bash
brew install swiftformat
swiftformat --version  # Verify version matches 0.58.7
```

**Option 2: Download specific version (recommended)**
```bash
curl -LO https://github.com/nicklockwood/SwiftFormat/releases/download/0.58.7/swiftformat.zip
unzip swiftformat.zip
sudo mv swiftformat /usr/local/bin/
```

**Option 3: Nix**

If you use Nix, the repository flake provides a dev shell with SwiftFormat
pinned to exactly the version above (plus SwiftLint):
```bash
nix develop
swiftformat --version  # 0.58.7
```

#### Usage

To format all Swift files in the project:
```bash
swiftformat .
```

To check formatting without making changes:
```bash
swiftformat --lint .
```

#### Pre-commit Hook (Recommended)

To automatically check formatting before each commit:
```bash
cp .github/hooks/pre-commit .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
```

## Localization

All user-facing strings must be localized. Add every new string to the
English (source) entries in `Whisky/Localizable.xcstrings`. **Do not add
other-language translations, and do not edit another language's entries, in a
PR** — hand-editing the string catalog tends to re-serialize the whole file
(producing huge, unreviewable diffs) and can silently drop existing
translations.

Translations are managed through Crowdin and synced automatically: the
[`Crowdin`](.github/workflows/Crowdin.yml) workflow uploads new English strings
to the project's Crowdin, and opens a `New translations from Crowdin` pull
request when translators add or update strings. To help translate, contribute
through the Crowdin project rather than opening a PR here.

## Changelog

We maintain a [CHANGELOG.md](CHANGELOG.md) following the [Keep a Changelog](https://keepachangelog.com/) format. When making user-facing changes, please update the changelog under the `[Unreleased]` section.

### Citing upstream issues

When a change closes or addresses an issue from the archived upstream
repository [whisky-app/whisky](https://github.com/whisky-app/whisky),
cite it in the CHANGELOG entry **and** the commit message using the
fully-qualified form:

```
(Closes whisky-app/whisky#1234, whisky-app/whisky#1235)
```

The per-issue audit (`scripts/audit_upstream.py`, see
[docs/AUDIT.md](docs/AUDIT.md)) greps the source tree and `git log` for
this exact pattern. Bare `#1234` doesn't count — the audit needs the
`whisky-app/whisky` prefix on each number to disambiguate from this
fork's own issue numbers.

For per-game compatibility fixes that are config-only, add or update the
matching entry in
`WhiskyCore/Sources/WhiskyCore/Resources/GameDB.json` and
include the upstream issue URL in the entry's `provenance.referenceURL`
field — the audit picks up that URL form too.

## Secret scanning

CI runs [TruffleHog](https://github.com/trufflesecurity/trufflehog) against
every PR and every push to `main`, configured to **only fail on verified
secrets** (i.e., the credential is real and currently active). Compiled
binaries in the bundled Wine libraries trigger false positives on byte
patterns that match Box/Eraser/NPM token formats, but those are unverified
and ignored.

To scan locally before pushing:

```bash
brew install trufflehog
./scripts/scan-secrets.sh        # scans HEAD vs origin/main
./scripts/scan-secrets.sh main   # scans HEAD vs local main
```

If the scan fails on a real secret, **rotate the credential first** (treat
it as compromised), then remove it from history with
[`git filter-repo`](https://github.com/newren/git-filter-repo) or
[BFG](https://rtyley.github.io/bfg-repo-cleaner/) and force-push the fix
through a coordinated rewrite.

## Testing

### Running Tests

Whisky has two test layers:

**Swift package unit tests** — WhiskyKit, WhiskyCore and WhiskyMetadata pure-Swift
logic, runnable without launching the app:

```bash
swift test --package-path WhiskyKit
swift test --package-path WhiskyCore
swift test --package-path WhiskyMetadata
```

**WhiskyBridge and GPUI tests** — exercise the shared application service and macOS frontend:

```bash
swift test --package-path WhiskyBridge
cargo test --locked --manifest-path apps/whisky-gpui/Cargo.toml
./build.sh run whisky-macos-gpui-arm64
```

> **Note:** the `Whisky/` SwiftUI app target and `WhiskyUITests/` UI suite are
> not yet covered in CI. The Python
> end-to-end suite under `tests/` (tier1–tier4) is currently developer-local
> only; it hardcodes a sample bottle path in `tests/common.py` and is not wired
> into any workflow.

All tests must pass before your PR can be merged.

### Testing Launcher Compatibility Features

If your changes affect launcher compatibility (Issue #41), please perform the following tests:

1.  **Unit Tests**: Ensure coverage for launcher detection, environment generation, and settings persistence.
2.  **Manual Testing**:
    -   Create a test bottle (Windows 10).
    -   Enable Launcher Compatibility Mode.
    -   Verify detection and configuration for the target launcher.
    -   Check that settings persist after restart.

### Regression Testing

Before submitting a PR, verify no regressions:

```bash
# Run full Swift test suite
swift test --package-path WhiskyKit
swift test --package-path WhiskyCore
swift test --package-path WhiskyMetadata

# Test and package the GPUI application
swift test --package-path WhiskyBridge
cargo test --locked --manifest-path apps/whisky-gpui/Cargo.toml
./build.sh run whisky-macos-gpui-arm64

# Check formatting
swiftformat --lint .
```

## Review Process

Once your pull request passes CI checks (SwiftLint, SwiftFormat, and builds), it will be ready for review.

### Review Checklist

- [ ] All tests pass (`swift test --package-path WhiskyKit`, `WhiskyCore`, `WhiskyMetadata`, `WhiskyBridge`)
- [ ] GPUI packaging succeeds (`./build.sh run whisky-macos-gpui-arm64`)
- [ ] SwiftFormat clean (`swiftformat --lint .`)
- [ ] SwiftLint clean (`swiftlint lint --strict`)
- [ ] Documentation updated (if adding features)
- [ ] Changelog updated (if user-facing changes)

Thank you for contributing to Whisky!
