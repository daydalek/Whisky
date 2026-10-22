# Linux bundle license inputs

`icu-76.1-LICENSE.txt` is the complete upstream ICU 76.1 license and third-party
notice file, preserved verbatim from:

https://raw.githubusercontent.com/unicode-org/icu/release-76-1/LICENSE

SHA-256: `01edac20612b1e590c1c1cfb02b7218c6adc7b0a944eda7a1e03aeee10725aed`.

The Swift 6.4 Linux toolchain's `_foundation_unicode/uvernum.h` identifies ICU
76.1 for `lib_FoundationICU.so`. The packager reads that header and requires a
matching preserved license before copying the runtime. The Swift toolchain's
own `share/swift/LICENSE.txt` is copied separately. The manifest records runtime
input hashes and the hashes after rewriting ELF RUNPATH values.

Locked Rust `.crate` source archives are verified against `Cargo.lock` checksums
and included with application sources. Supplied crate license/notice texts are
copied alongside their manifest license declarations in `dependencies.json`.
The sources retain additional notices embedded inside individual crates.
