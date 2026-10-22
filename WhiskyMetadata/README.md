# WhiskyMetadata

Shared public metadata providers, metadata/artwork storage and native image
validation. `WhiskyCore` supplies the Foundation-only models and identities;
this package owns URLSession transport and the platform decoder boundary.

- macOS uses ImageIO. Linux uses GdkPixbuf and its WebP loader.
- Pass a `MetadataNetworkAccess` closure to each provider/store. It is checked
  before transport, including YMGal token refresh and authentication retries.
- WhiskyKit's existing names remain typealiases with convenience initializers
  that supply `NetworkSettings.requireNetwork`. The Linux bridge supplies its
  live XDG-backed offline preference.
- Storage filenames, cover selection, manual unlink markers and provider
  snapshots retain their existing on-disk representation.

Ubuntu build/runtime dependencies are `libgdk-pixbuf-2.0-dev` and
`webp-pixbuf-loader` (the development package brings pkg-config metadata).
Run `swift test --package-path WhiskyMetadata`; Swift 6.4 Linux uses
`--build-system native` to avoid the default engine's C-module test-runner
collision. The foundation checker runs this suite with the appropriate flag.

The tests exercise provider parsing, pacing, caching and authentication with
URLProtocol fixtures, plus complete PNG/JPEG/GIF/WebP pixel decoding. Live
provider availability is checked separately by `check-metadata.py --live`.
