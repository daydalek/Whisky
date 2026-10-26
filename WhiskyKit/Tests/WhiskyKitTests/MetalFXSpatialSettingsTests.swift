//
//  MetalFXSpatialSettingsTests.swift
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

final class MetalFXSpatialSettingsTests: XCTestCase {
    func testLegacyMetadataDefaultsToOffAndRoundTripsOptIn() throws {
        let old = try PropertyListSerialization.data(fromPropertyList: [:], format: .xml, options: 0)
        let legacy = try PropertyListDecoder().decode(BottleGraphicsConfig.self, from: old)
        XCTAssertFalse(legacy.metalFXSpatial)
        var settings = BottleSettings()
        XCTAssertFalse(settings.metalFXSpatial)
        settings.metalFXSpatial = true
        let data = try PropertyListEncoder().encode(settings)
        let restored = try PropertyListDecoder().decode(BottleSettings.self, from: data)
        XCTAssertTrue(restored.metalFXSpatial)
    }

    func testLaunchEnvironmentFollowsSwitchAcrossBackends() {
        for backend in [GraphicsBackend.d3dMetal, .dxvk, .dxmt, .wined3d] {
            var settings = BottleSettings()
            settings.graphicsBackend = backend
            var off = EnvironmentBuilder()
            _ = settings.populateBottleManagedLayer(builder: &off, builtinD3D12IsD3DMetal: false)
            XCTAssertEqual(off.resolve().environment["WINE_METALFX"], "off")
            settings.metalFXSpatial = true
            var enabled = EnvironmentBuilder()
            _ = settings.populateBottleManagedLayer(builder: &enabled, builtinD3D12IsD3DMetal: false)
            XCTAssertEqual(enabled.resolve().environment["WINE_METALFX"], "spatial")
            enabled.set("WINE_METALFX", "off", layer: .programUser)
            XCTAssertEqual(enabled.resolve().environment["WINE_METALFX"], "off")
        }
    }
}
