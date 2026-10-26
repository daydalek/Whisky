//
//  GDIUpscalerSettingsTests.swift
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

@testable import WhiskyKit
import XCTest

final class GDIUpscalerSettingsTests: XCTestCase {
    func testLegacyAndExplicitMetadataSelection() throws {
        let cases: [([String: Any], GDIUpscaler)] = [
            ([:], .off), (["metalFXSpatial": true], .metalfx),
            (["metalFXSpatial": false], .off),
            (["metalFXSpatial": true, "gdiUpscaler": "off"], .off),
            (["metalFXSpatial": true, "gdiUpscaler": "anime4k"], .anime4k),
            (["gdiUpscaler": "realcugan"], .realcugan),
            (["gdiUpscaler": "future-algorithm"], .off),
            (["gdiUpscaler": 42], .off)
        ]
        for (document, expected) in cases {
            let bytes = try PropertyListSerialization.data(fromPropertyList: document, format: .xml, options: 0)
            let config = try PropertyListDecoder().decode(BottleGraphicsConfig.self, from: bytes)
            XCTAssertEqual(config.gdiUpscaler, expected)
        }
    }

    func testAlgorithmPersistenceAndCompatibilityAlias() throws {
        var settings = BottleSettings()
        XCTAssertEqual(settings.gdiUpscaler, .off)
        for algorithm in GDIUpscaler.allCases {
            settings.gdiUpscaler = algorithm
            let bytes = try PropertyListEncoder().encode(settings)
            let restored = try PropertyListDecoder().decode(BottleSettings.self, from: bytes)
            XCTAssertEqual(restored.gdiUpscaler, algorithm)
            XCTAssertEqual(restored.metalFXSpatial, algorithm == .metalfx)
        }
        settings.metalFXSpatial = true
        XCTAssertEqual(settings.gdiUpscaler, .metalfx)
        settings.metalFXSpatial = false
        XCTAssertEqual(settings.gdiUpscaler, .off)
    }

    func testEveryAlgorithmReachesLaunchEnvironmentAcrossBackends() {
        for backend in [GraphicsBackend.d3dMetal, .dxvk, .dxmt, .wined3d] {
            var settings = BottleSettings()
            settings.graphicsBackend = backend
            for algorithm in GDIUpscaler.allCases {
                settings.gdiUpscaler = algorithm
                var builder = EnvironmentBuilder()
                _ = settings.populateBottleManagedLayer(builder: &builder, builtinD3D12IsD3DMetal: false)
                XCTAssertEqual(builder.resolve().environment["WINE_GDI_UPSCALER"], algorithm.rawValue)
                XCTAssertEqual(builder.resolve().environment["WINE_METALFX"], algorithm == .metalfx ? "spatial" : "off")
                XCTAssertEqual(settings.graphicsBackend, backend)
                XCTAssertFalse(settings.frameGeneration)
                builder.set("WINE_GDI_UPSCALER", "off", layer: .programUser)
                XCTAssertEqual(builder.resolve().environment["WINE_GDI_UPSCALER"], "off")
            }
        }
    }
}
