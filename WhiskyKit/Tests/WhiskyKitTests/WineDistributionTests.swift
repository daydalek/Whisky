//
//  WineDistributionTests.swift
//  WhiskyKitTests
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import SemanticVersion
@testable import WhiskyKit
import XCTest

final class WineDistributionTests: XCTestCase {
    func testExplicitAssetURLSupportsDifferentReleaseTagAndRuntimeVersion() throws {
        let manifest = WhiskyWineVersion(
            version: SemanticVersion(11, 0, 1),
            downloadURL:
            "https://github.com/daydalek/ge-proton-macos-wine-poc/releases/download/v0.1.0/Libraries.tar.gz"
        )
        XCTAssertTrue(try DistributionConfig.librariesURL(for: manifest).path.contains("/v0.1.0/"))
        let decoded = try PropertyListDecoder().decode(
            WhiskyWineVersion.self, from: PropertyListEncoder().encode(manifest)
        )
        XCTAssertEqual(decoded.downloadURL, manifest.downloadURL)
    }

    func testArchiveURLValidation() throws {
        for value in [
            "http://github.com/daydalek/ge-proton-macos-wine-poc/releases/download/v1/Libraries.tar.gz",
            "https://example.com/Libraries.tar.gz",
            "https://github.com/other/repo/releases/download/v1/Libraries.tar.gz",
            "https://github.com/daydalek/ge-proton-macos-wine-poc/releases/download/v1/Other.tar.gz"
        ] {
            let manifest = WhiskyWineVersion(version: SemanticVersion(1, 0, 0), downloadURL: value)
            XCTAssertThrowsError(try DistributionConfig.librariesURL(for: manifest))
        }
    }

    func testLegacyManifestUsesVersionTag() throws {
        let manifest = WhiskyWineVersion(version: SemanticVersion(2, 5, 0))
        XCTAssertEqual(
            try DistributionConfig.librariesURL(for: manifest).absoluteString,
            DistributionConfig.librariesURL(version: "2.5.0")
        )
    }

    /// Tests URL construction with edge case version numbers
    func testURLConstructionEdgeCases() {
        // Test with zero version
        let zeroURL = DistributionConfig.librariesURL(version: "0.0.0")
        let expectedZeroURL = "https://github.com/daydalek/ge-proton-macos-wine-poc/releases/download"
            + "/v0.0.0/Libraries.tar.gz"
        XCTAssertEqual(zeroURL, expectedZeroURL)
        XCTAssertNotNil(URL(string: zeroURL))

        // Test with large version numbers
        let largeURL = DistributionConfig.librariesURL(version: "999.999.999")
        let expectedLargeURL = "https://github.com/daydalek/ge-proton-macos-wine-poc/releases/download"
            + "/v999.999.999/Libraries.tar.gz"
        XCTAssertEqual(largeURL, expectedLargeURL)
        XCTAssertNotNil(URL(string: largeURL))
    }
}
