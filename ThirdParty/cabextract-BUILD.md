# cabextract 1.11 build provenance

- Official source: https://www.cabextract.org.uk/cabextract-1.11.tar.gz
- Source archive SHA-256: `b5546db1155e4c718ff3d4b278573604f30dd64c3c5bfd4657cd089b823a3ac6`
- Local archive: `sources/cabextract-1.11.tar.gz`.
- Upstream sources are unmodified; bundled libmspack is compiled into the tool.
- Replacement of the inherited prebuilt executable: 2026-10-19.
- Compiler used for this replacement: Apple clang 21.0.0 (clang-2100.3.33.1),
  macOS SDK 27.0, arm64, deployment target macOS 14.0.
- Build flags: `-O2 -arch arm64 -mmacosx-version-min=14.0`;
  link flags: `-arch arm64 -mmacosx-version-min=14.0`.
- Validation: upstream `make check`, 12 tests passed; arm64; dependencies
  `/usr/lib/libiconv.2.dylib` and `/usr/lib/libSystem.B.dylib`.

From the repository root, run:

```sh
bash scripts/build-cabextract.sh /tmp/whisky-cabextract-rebuild
```

The script verifies and extracts the preserved archive, configures the build,
compiles the executable, and runs upstream tests. Its output is
`/tmp/whisky-cabextract-rebuild/cabextract-1.11/cabextract`.
Copy that executable to `Libraries/cabextract` when updating the tracked build,
and update its hash in `ThirdParty/manifest.json` after reviewing the change.
The compiler, SDK, and signing can affect binary bytes; the manifest records the
tracked executable before Xcode's code-sign-on-copy step.
