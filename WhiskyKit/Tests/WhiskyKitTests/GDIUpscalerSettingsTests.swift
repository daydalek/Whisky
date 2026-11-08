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
            (["gdiUpscaler": "realesrgan"], .realesrgan),
            (["gdiUpscaler": "adaptive-realesrgan"], .adaptiveRealesrgan),
            (["gdiUpscaler": "adaptive-anime4k"], .adaptiveAnime4k),
            (["gdiUpscaler": "adaptive-anime4k-realesrgan"], .adaptiveAnime4kRealesrgan),
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
        // The Wine driver keeps only the original WINE_GDI_UPSCALER vocabulary;
        // Real-ESRGAN selections ride the neural-model variable instead.
        let upscalerValue: [GDIUpscaler: String] = [
            .realesrgan: "realcugan",
            .adaptiveRealesrgan: "adaptive",
            .adaptiveAnime4k: "adaptive",
            .adaptiveAnime4kRealesrgan: "adaptive"
        ]
        for backend in [GraphicsBackend.d3dMetal, .dxvk, .dxmt, .wined3d] {
            var settings = BottleSettings()
            settings.graphicsBackend = backend
            for algorithm in GDIUpscaler.allCases {
                settings.gdiUpscaler = algorithm
                var builder = EnvironmentBuilder()
                _ = settings.populateBottleManagedLayer(builder: &builder, builtinD3D12IsD3DMetal: false)
                XCTAssertEqual(
                    builder.resolve().environment["WINE_GDI_UPSCALER"],
                    upscalerValue[algorithm] ?? algorithm.rawValue
                )
                XCTAssertEqual(
                    builder.resolve().environment["WINE_GDI_NEURAL_MODEL"],
                    [.realesrgan, .adaptiveRealesrgan, .adaptiveAnime4kRealesrgan].contains(algorithm)
                        ? "animevideov3" : "realcugan"
                )
                XCTAssertEqual(
                    builder.resolve().environment["WINE_GDI_ADAPTIVE_FAST"],
                    [.adaptiveAnime4k, .adaptiveAnime4kRealesrgan].contains(algorithm)
                        ? "anime4k" : "metalfx"
                )
                XCTAssertEqual(builder.resolve().environment["WINE_METALFX"], algorithm == .metalfx ? "spatial" : "off")
                XCTAssertEqual(settings.graphicsBackend, backend)
                XCTAssertFalse(settings.frameGeneration)
                builder.set("WINE_GDI_UPSCALER", "off", layer: .programUser)
                XCTAssertEqual(builder.resolve().environment["WINE_GDI_UPSCALER"], "off")
            }
        }
    }

    func testProgramUpscalerOverridesInheritAndDecode() throws {
        // Old plists without the new keys decode as inherit-everything.
        let empty = try PropertyListDecoder().decode(
            ProgramOverrides.self,
            from: PropertyListSerialization.data(
                fromPropertyList: ["dxvkAsync": true], format: .xml, options: 0
            )
        )
        XCTAssertNil(empty.gdiUpscaler)
        XCTAssertNil(empty.gdiUpscalerCache)
        XCTAssertEqual(empty.dxvkAsync, true)
        XCTAssertFalse(empty.isEmpty)

        var overrides = ProgramOverrides()
        overrides.gdiUpscaler = .adaptiveRealesrgan
        overrides.gdiUpscalerCache = .persistent
        let restored = try PropertyListDecoder().decode(
            ProgramOverrides.self, from: PropertyListEncoder().encode(overrides)
        )
        XCTAssertEqual(restored.gdiUpscaler, .adaptiveRealesrgan)
        XCTAssertEqual(restored.gdiUpscalerCache, .persistent)
        XCTAssertFalse(ProgramOverrides().isEmpty == restored.isEmpty)
    }

    func testProgramUpscalerOverridesBeatBottleLayer() {
        var settings = BottleSettings()
        settings.gdiUpscaler = .realcugan
        settings.gdiUpscalerCache = .persistent
        var builder = EnvironmentBuilder()
        _ = settings.populateBottleManagedLayer(builder: &builder, builtinD3D12IsD3DMetal: false)
        let makeResolver = {
            DLLOverrideResolver(managed: [], bottleCustom: [], programCustom: [])
        }

        let upscalerValue: [GDIUpscaler: String] = [
            .realesrgan: "realcugan",
            .adaptiveRealesrgan: "adaptive",
            .adaptiveAnime4k: "adaptive",
            .adaptiveAnime4kRealesrgan: "adaptive"
        ]
        for algorithm in GDIUpscaler.allCases {
            var overrides = ProgramOverrides()
            overrides.gdiUpscaler = algorithm
            overrides.gdiUpscalerCache = .off
            var trial = builder
            var resolver = makeResolver()
            Wine.applyProgramOverrides(
                overrides, builtinD3D12IsD3DMetal: false,
                builder: &trial, dllResolver: &resolver
            )
            let env = trial.resolve().environment
            XCTAssertEqual(env["WINE_GDI_UPSCALER"], upscalerValue[algorithm] ?? algorithm.rawValue)
            XCTAssertEqual(
                env["WINE_GDI_NEURAL_MODEL"],
                [.realesrgan, .adaptiveRealesrgan, .adaptiveAnime4kRealesrgan].contains(algorithm)
                    ? "animevideov3" : "realcugan"
            )
            XCTAssertEqual(
                env["WINE_GDI_ADAPTIVE_FAST"],
                [.adaptiveAnime4k, .adaptiveAnime4kRealesrgan].contains(algorithm)
                    ? "anime4k" : "metalfx"
            )
            XCTAssertEqual(env["WINE_METALFX"], algorithm == .metalfx ? "spatial" : "off")
            XCTAssertEqual(env["WINE_GDI_CACHE_MODE"], "off")
        }

        // No override: bottle values survive untouched.
        var resolver = makeResolver()
        var untouched = builder
        Wine.applyProgramOverrides(
            ProgramOverrides(), builtinD3D12IsD3DMetal: false,
            builder: &untouched, dllResolver: &resolver
        )
        XCTAssertEqual(untouched.resolve().environment["WINE_GDI_UPSCALER"], "realcugan")
        XCTAssertEqual(untouched.resolve().environment["WINE_GDI_CACHE_MODE"], "persistent")
    }

    func testCacheModeDecodingAndRoundtrip() throws {
        let cases: [([String: Any], GDIUpscalerCacheMode)] = [
            ([:], .memory),
            (["gdiUpscalerCache": "off"], .off),
            (["gdiUpscalerCache": "memory"], .memory),
            (["gdiUpscalerCache": "persistent"], .persistent),
            (["gdiUpscalerCache": "future-mode"], .memory),
            (["gdiUpscalerCache": 42], .memory)
        ]
        for (document, expected) in cases {
            let bytes = try PropertyListSerialization.data(fromPropertyList: document, format: .xml, options: 0)
            let config = try PropertyListDecoder().decode(BottleGraphicsConfig.self, from: bytes)
            XCTAssertEqual(config.gdiUpscalerCache, expected)
        }
        var settings = BottleSettings()
        for mode in GDIUpscalerCacheMode.allCases {
            settings.gdiUpscalerCache = mode
            let bytes = try PropertyListEncoder().encode(settings)
            let restored = try PropertyListDecoder().decode(BottleSettings.self, from: bytes)
            XCTAssertEqual(restored.gdiUpscalerCache, mode)
        }
    }

    func testCacheModeReachesLaunchEnvironmentAcrossBackends() {
        for backend in [GraphicsBackend.d3dMetal, .dxvk, .dxmt, .wined3d] {
            var settings = BottleSettings()
            settings.graphicsBackend = backend
            for mode in GDIUpscalerCacheMode.allCases {
                settings.gdiUpscalerCache = mode
                var builder = EnvironmentBuilder()
                _ = settings.populateBottleManagedLayer(builder: &builder, builtinD3D12IsD3DMetal: false)
                XCTAssertEqual(builder.resolve().environment["WINE_GDI_CACHE_MODE"], mode.rawValue)
                builder.set("WINE_GDI_CACHE_MODE", "off", layer: .programUser)
                XCTAssertEqual(builder.resolve().environment["WINE_GDI_CACHE_MODE"], "off")
            }
        }
    }

    @MainActor
    func testCacheGameIdentityComesFromCanonicalTarget() throws {
        let tempURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let bottle = Bottle(bottleUrl: tempURL, inFlight: false, isAvailable: true)
        let game = tempURL.appending(path: "drive_c/game.exe")
        try FileManager.default.createDirectory(
            at: game.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data().write(to: game)
        let alias = tempURL.appending(path: "alias.exe")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: game)

        let direct = Wine.constructWineEnvironment(for: bottle, targetURL: game)
        XCTAssertEqual(
            direct["WINE_GDI_CACHE_DIRECTORY"],
            FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Caches/com.isaacmarovitz.Whisky/GDIUpscaler").path
        )
        XCTAssertEqual(
            direct["WINE_GDI_CACHE_GAME"],
            game.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        )
        let linked = Wine.constructWineEnvironment(for: bottle, targetURL: alias)
        XCTAssertEqual(linked["WINE_GDI_CACHE_GAME"], direct["WINE_GDI_CACHE_GAME"])
        let absent = Wine.constructWineEnvironment(for: bottle)
        XCTAssertNil(absent["WINE_GDI_CACHE_GAME"])
        let overridden = Wine.constructWineEnvironment(
            for: bottle, environment: ["WINE_GDI_CACHE_GAME": "explicit"], targetURL: game
        )
        XCTAssertEqual(overridden["WINE_GDI_CACHE_GAME"], "explicit")
        let customRoot = Wine.constructWineEnvironment(
            for: bottle, environment: ["WINE_GDI_CACHE_DIRECTORY": "/tmp/custom-cache"], targetURL: game
        )
        XCTAssertEqual(customRoot["WINE_GDI_CACHE_DIRECTORY"], "/tmp/custom-cache")
    }

    func testRegionProfilesAreIsolatedByGameAndBottle() {
        let bottle = URL(fileURLWithPath: "/tmp/bottle-a")
        let first = URL(fileURLWithPath: "/tmp/bottle-a/drive_c/GameA/game.exe")
        let second = URL(fileURLWithPath: "/tmp/bottle-a/drive_c/GameB/game.exe")
        let profile = Program.upscaleRegionProfileURL(for: first, bottleURL: bottle)
        XCTAssertEqual(profile, Program.upscaleRegionProfileURL(for: first, bottleURL: bottle))
        XCTAssertNotEqual(profile, Program.upscaleRegionProfileURL(for: second, bottleURL: bottle))
        XCTAssertNotEqual(
            profile,
            Program.upscaleRegionProfileURL(for: first, bottleURL: URL(fileURLWithPath: "/tmp/bottle-b"))
        )
        XCTAssertEqual(profile.pathExtension, "regions")
    }

    @MainActor
    func testLaunchPassesGameProfileAndProgramSelectionMode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = Bottle(bottleUrl: root, inFlight: false, isAvailable: true)
        let game = root.appendingPathComponent("drive_c/Game/game.exe")
        let env = Wine.constructWineEnvironment(
            for: bottle, environment: ["WINE_GDI_UPSCALER_PICK": "off"], targetURL: game,
            recommendedBackend: .wined3d, builtinD3D12IsD3DMetal: false
        )
        XCTAssertEqual(
            env["WINE_GDI_UPSCALER_EXCLUDE_PROFILE"],
            Program.upscaleRegionProfileURL(for: game, bottleURL: root).path(percentEncoded: false)
        )
        XCTAssertEqual(env["WINE_GDI_UPSCALER_PICK"], "off")
    }

    func testLegacyExcludedRegionsPersist() throws {
        var settings = BottleSettings()
        XCTAssertEqual(settings.gdiUpscalerExcludedRegions, "")
        settings.gdiUpscalerExcludedRegions = "0,520,1280,200;10,10,100,30"
        let restored = try PropertyListDecoder().decode(
            BottleSettings.self, from: PropertyListEncoder().encode(settings)
        )
        XCTAssertEqual(restored.gdiUpscalerExcludedRegions, settings.gdiUpscalerExcludedRegions)
    }

    @MainActor
    func testRegionEnvironmentAndProfileCanonicalization() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = Bottle(bottleUrl: root, inFlight: false, isAvailable: true)
        let game = root.appendingPathComponent("drive_c/Game/game.exe")
        try FileManager.default.createDirectory(
            at: game.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data().write(to: game)
        let alias = root.appendingPathComponent("alias.exe")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: game)
        XCTAssertEqual(
            Program.upscaleRegionProfileURL(for: game, bottleURL: root),
            Program.upscaleRegionProfileURL(for: alias, bottleURL: root)
        )
        let other = root.appendingPathComponent("drive_c/Other/other.exe")
        XCTAssertNotEqual(
            Program.upscaleRegionProfileURL(for: game, bottleURL: root),
            Program.upscaleRegionProfileURL(for: other, bottleURL: root)
        )
        bottle.settings.gdiUpscalerExcludedRegions = "0,520,1280,200"
        let populated = Wine.constructWineEnvironment(for: bottle, targetURL: game)
        XCTAssertEqual(populated["WINE_GDI_UPSCALER_EXCLUDE"], "0,520,1280,200")
        let overridden = Wine.constructWineEnvironment(
            for: bottle, environment: ["WINE_GDI_UPSCALER_EXCLUDE": "1,2,3,4"],
            targetURL: game
        )
        XCTAssertEqual(overridden["WINE_GDI_UPSCALER_EXCLUDE"], "1,2,3,4")
        let profile = populated["WINE_GDI_UPSCALER_EXCLUDE_PROFILE"]
        XCTAssertNotNil(profile)
        XCTAssertFalse((profile ?? "").isEmpty)
    }
}
