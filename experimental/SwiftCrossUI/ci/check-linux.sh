#!/usr/bin/env bash
set -euo pipefail

prototype_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
portability_build_dir="${WHISKY_CROSSUI_BUILD_DIR:-$prototype_dir/../../build/portability/linux-crossui/swiftpm}"

swift --version
"${CC:-clang}" --version
pkg-config --modversion gtk4
# Swift 6.4's default engine includes WinUIInterop in this Linux dependency graph.
# Its native engine applies the package's conditional backend dependencies.
swift build --package-path "$prototype_dir" --scratch-path "$portability_build_dir" \
    --build-system native --force-resolved-versions --jobs 4 --product WhiskyCrossUI
# Select this package's complete test product; the broad test build also plans
# unused Windows static-library products from transitive packages in Swift 6.4.
swift test --package-path "$prototype_dir" --scratch-path "$portability_build_dir" \
    --build-system native --force-resolved-versions --jobs 4 \
    --test-product WhiskyCrossUIPackageTests
