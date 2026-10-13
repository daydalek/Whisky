//
//  ProgramEnvironmentPresetTests.swift
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

import Foundation
import Testing
@testable import WhiskyKit

@Suite("Program environment presets")
struct ProgramEnvironmentPresetTests {
    @Test("Locale shortcuts replace prior locale values and preserve other settings")
    func localePreset() {
        var settings = ProgramSettings()
        settings.environment = ["LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "CUSTOM": "kept"]
        for locale in [Locales.japanese, .chineseSimplified, .chineseTraditional] {
            settings.applyLocalePreset(locale)
            #expect(settings.locale == locale)
            #expect(settings.environment["LANG"] == locale.rawValue)
            #expect(settings.environment["LC_ALL"] == locale.rawValue)
            #expect(settings.environment["CUSTOM"] == "kept")
        }
        settings.applyLocalePreset(.auto)
        #expect(settings.locale == .auto)
        #expect(settings.environment["LANG"] == nil)
        #expect(settings.environment["LC_ALL"] == nil)
        #expect(settings.environment["CUSTOM"] == "kept")
    }

    @Test("Switching renderers preserves WineD3D tuning and resets only renderer")
    func rendererPreset() {
        var settings = ProgramSettings()
        settings.environment = ["WINE_D3D_CONFIG": "csmt=0x1, renderer=gl,shader_backend=glsl", "CUSTOM": "kept"]
        settings.applyWineD3DRenderer(.gdi)
        #expect(settings.environment["WINE_D3D_CONFIG"] == "csmt=0x1,shader_backend=glsl,renderer=gdi")
        #expect(settings.wineD3DRenderer == .gdi)
        settings.applyWineD3DRenderer(.vulkan)
        #expect(settings.environment["WINE_D3D_CONFIG"] == "csmt=0x1,shader_backend=glsl,renderer=vulkan")
        settings.applyWineD3DRenderer(.automatic)
        #expect(settings.environment["WINE_D3D_CONFIG"] == "csmt=0x1,shader_backend=glsl")
        #expect(settings.wineD3DRenderer == .automatic)
        #expect(settings.environment["CUSTOM"] == "kept")
        settings.environment["WINE_D3D_CONFIG"] = "renderer=no3d"
        #expect(settings.wineD3DRenderer == .gdi)
        settings.applyWineD3DRenderer(.automatic)
        #expect(settings.environment["WINE_D3D_CONFIG"] == nil)
        settings.environment["WINE_D3D_CONFIG"] = "renderer=custom"
        #expect(settings.wineD3DRenderer == nil)
    }

    @Test("Shortcut settings persist and enter the environment after reloading a program")
    @MainActor func persistedPresets() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = Bottle(bottleUrl: root, inFlight: false, isAvailable: true)
        let exe = root.appending(path: "drive_c/Game.exe")
        let editor = Program(url: exe, bottle: bottle, peFile: nil)
        editor.settings.applyLocalePreset(.japanese)
        editor.settings.applyWineD3DRenderer(.gdi)
        let reloaded = Program(url: exe, bottle: bottle, peFile: nil)
        let env = Wine.constructWineEnvironment(for: bottle, environment: reloaded.generateEnvironment())
        #expect(env["LANG"] == "ja_JP.UTF-8")
        #expect(env["LC_ALL"] == "ja_JP.UTF-8")
        #expect(env["WINE_D3D_CONFIG"] == "renderer=gdi")
    }
}
