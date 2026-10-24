//
//  PlatformPortabilityTests.swift
//  WhiskyCore
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
@testable import WhiskyCore

@Suite("Cross-platform path and schema portability")
struct PlatformPortabilityTests {
    @Test func caseInsensitivePathResolvesMismatchedOnDiskCasing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let steamDir = root
            .appendingPathComponent("Drive_C")
            .appendingPathComponent("program files (x86)")
            .appendingPathComponent("STEAM")
        try FileManager.default.createDirectory(at: steamDir, withIntermediateDirectories: true)
        let exe = steamDir.appendingPathComponent("Steam.EXE")
        try Data([0x4D, 0x5A]).write(to: exe)

        let resolved = CaseInsensitivePath.resolve(
            base: root,
            relativePath: "drive_c/Program Files (x86)/Steam/steam.exe",
            forceDirectoryLookup: true
        )
        #expect(resolved.lastPathComponent == "Steam.EXE")
        #expect(resolved.deletingLastPathComponent().lastPathComponent == "STEAM")
        #expect(SteamLibrary.detectInstall(bottleURL: root) != nil)
    }

    @Test func installedProgramsDiscoversUppercaseExeAndSkipsClickOnceCaseInsensitively() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let driveC = root.appendingPathComponent("drive_c")
        let gameDir = driveC.appendingPathComponent("Program Files/RetroGame")
        let clickOnceDir = driveC.appendingPathComponent("Program Files/Vendor/apps/2.0/Cache")
        try FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: clickOnceDir, withIntermediateDirectories: true)
        let upperExe = gameDir.appendingPathComponent("LAUNCH.EXE")
        let mixedExe = gameDir.appendingPathComponent("Config.Exe")
        let clickOnceExe = clickOnceDir.appendingPathComponent("helper.exe")
        for file in [upperExe, mixedExe, clickOnceExe] {
            try Data([0x4D, 0x5A]).write(to: file)
        }

        let found = InstalledPrograms.discoverInstalledExecutables(driveC: driveC, blocklist: [mixedExe])
        #expect(found.map(\.lastPathComponent) == ["LAUNCH.EXE"])
    }

    @Test func platformFilteredConfigurationSchemaExcludesMacOSOnlySettingsOnLinux() {
        let linuxFields = ContainerConfiguration.fields(for: .linux)
        let linuxIDs = Set(linuxFields.map(\.id))
        #expect(!linuxIDs.contains("metalFX"))
        #expect(!linuxIDs.contains("metalHud"))
        #expect(!linuxIDs.contains("commandActsAsControl"))
        #expect(!linuxIDs.contains("disableAppNap"))
        #expect(linuxIDs.contains("windowsVersion"))
        #expect(linuxIDs.contains("dxvkAsync"))

        let graphics = linuxFields.first { $0.id == "graphicsBackend" }
        if case let .choice(options) = graphics?.input {
            let optionIDs = Set(options.map(\.id))
            #expect(optionIDs == ["recommended", "dxvk", "wined3d"])
        } else {
            Issue.record("Expected graphicsBackend choice field")
        }

        let macFields = ContainerConfiguration.fields(for: .macOS)
        #expect(macFields.count == ContainerConfiguration.fields.count)
        #expect(ContainerConfiguration.fields.allSatisfy { !$0.titleKey.isEmpty })
    }

    @Test func virtualDesktopResolutionAndClipboardPreflightReadFromPortableConfiguration() async throws {
        let preset = ContainerConfiguration.virtualDesktopResolution(
            from: ["resolutionPreset": .text("r2560x1440")]
        )
        #expect(preset == "2560x1440")
        let custom = ContainerConfiguration.virtualDesktopResolution(
            from: [
                "resolutionPreset": .text("custom"),
                "customResolutionWidth": .integer(3_440),
                "customResolutionHeight": .integer(1_440)
            ]
        )
        #expect(custom == "3440x1440")
        let display = ContainerConfiguration.virtualDesktopResolution(
            from: ["resolutionPreset": .text("matchDisplay")],
            displayDimensions: { (width: 1_920, height: 1_200) }
        )
        #expect(display == "1920x1200")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let plist = root.appendingPathComponent("Metadata.plist")
        let doc: [String: Any] = [
            "launcherConfig": ["detectedLauncher": LauncherType.steam.rawValue],
            "cleanupConfig": ["clipboardPolicy": "warn", "clipboardThreshold": 4_096]
        ]
        try PropertyListSerialization.data(fromPropertyList: doc, format: .binary, options: 0).write(to: plist)
        let store = ConfigurationFile(url: plist, locking: ConfigurationFileTests.Lock())
        let config = try await store.clipboardPreflightConfiguration()
        #expect(config.launcher == .steam)
        #expect(config.policy == .alwaysWarn)
        #expect(config.threshold == 4_096)
    }
}
