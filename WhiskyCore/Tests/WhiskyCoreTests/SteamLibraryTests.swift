// swiftlint:disable file_length
//
//  SteamLibraryTests.swift
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
@testable import WhiskyCore

private func acf(
    appId: Int, name: String, installDir: String, stateFlags: Int, lastPlayed: Int = 1_760_000_000
) -> String {
    """
    "AppState"
    {
        "appid"        "\(appId)"
        "name"        "\(name)"
        "installdir"        "\(installDir)"
        "StateFlags"        "\(stateFlags)"
        "buildid"        "1785187029"
        "SizeOnDisk"        "541968407"
        "LastPlayed"        "\(lastPlayed)"
    }
    """
}

@Suite("SteamLibrary Tests")
// swiftlint:disable:next type_body_length
struct SteamLibraryTests {
    /// Builds a fixture bottle: a default Steam install with one installed
    /// game, one downloading game, one manifest whose install dir is missing,
    /// plus a second library on D: (via dosdevices symlink) with another
    /// installed game and a duplicate of the first game's App ID.
    private func makeFixtureBottle() throws -> (bottle: URL, tempRoot: URL) {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appending(path: "steamlib_\(UUID().uuidString)")
        let bottle = tempRoot.appending(path: "bottle")
        let steamRoot = bottle.appending(path: "drive_c")
            .appending(path: "Program Files (x86)").appending(path: "Steam")
        let steamApps = steamRoot.appending(path: "steamapps")

        try fileManager.createDirectory(
            at: steamApps.appending(path: "common").appending(path: "Casualties Unknown Demo"),
            withIntermediateDirectories: true
        )
        try Data().write(to: steamRoot.appending(path: "steam.exe"))

        try Data(acf(
            appId: 4_576_510, name: "Casualties: Unknown Demo",
            installDir: "Casualties Unknown Demo", stateFlags: 4
        ).utf8).write(to: steamApps.appending(path: "appmanifest_4576510.acf"))

        // Downloading: filtered by state
        try Data(acf(appId: 999, name: "Downloading Game", installDir: "dl", stateFlags: 2).utf8)
            .write(to: steamApps.appending(path: "appmanifest_999.acf"))

        // Claims installed but common dir is missing: filtered
        try Data(acf(appId: 777, name: "Ghost Game", installDir: "Ghost", stateFlags: 4).utf8)
            .write(to: steamApps.appending(path: "appmanifest_777.acf"))

        try makeSecondLibrary(tempRoot: tempRoot, bottle: bottle)

        let config = steamRoot.appending(path: "config")
        try fileManager.createDirectory(at: config, withIntermediateDirectories: true)
        let vdf = """
        "libraryfolders"
        {
            "0"
            {
                "path"        "C:\\\\Program Files (x86)\\\\Steam"
            }
            "1"
            {
                "path"        "D:\\\\"
            }
        }
        """
        try Data(vdf.utf8).write(to: config.appending(path: "libraryfolders.vdf"))

        return (bottle, tempRoot)
    }

    /// A second library on D: reached through the dosdevices symlink, holding
    /// another installed game plus a duplicate of the first library's App ID.
    private func makeSecondLibrary(tempRoot: URL, bottle: URL) throws {
        let fileManager = FileManager.default
        let secondLibrary = tempRoot.appending(path: "second-library")
        let secondApps = secondLibrary.appending(path: "steamapps")
        try fileManager.createDirectory(
            at: secondApps.appending(path: "common").appending(path: "ELDEN RING"),
            withIntermediateDirectories: true
        )
        try Data(acf(appId: 1_245_620, name: "ELDEN RING", installDir: "ELDEN RING", stateFlags: 4).utf8)
            .write(to: secondApps.appending(path: "appmanifest_1245620.acf"))

        try Data(acf(
            appId: 4_576_510, name: "Casualties Duplicate",
            installDir: "ELDEN RING", stateFlags: 4
        ).utf8).write(to: secondApps.appending(path: "appmanifest_dup.acf"))

        let dosDevices = bottle.appending(path: "dosdevices")
        try fileManager.createDirectory(at: dosDevices, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: dosDevices.appending(path: "d:"),
            withDestinationURL: secondLibrary
        )
    }

    @Test("Detects a Steam install")
    func detectsInstall() throws {
        let (bottle, tempRoot) = try makeFixtureBottle()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let root = try #require(SteamLibrary.detectInstall(bottleURL: bottle))
        #expect(root.lastPathComponent == "Steam")
    }

    @Test("Returns nil for a bottle without Steam")
    func noSteamNoInstall() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tempDir.appending(path: "drive_c"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        #expect(SteamLibrary.detectInstall(bottleURL: tempDir) == nil)
        #expect(SteamLibrary.enumerate(bottleURL: tempDir).isEmpty)
    }

    @Test("Enumerates installed games across libraries, filtered and sorted")
    func enumeratesAcrossLibraries() throws {
        let (bottle, tempRoot) = try makeFixtureBottle()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let games = SteamLibrary.enumerate(bottleURL: bottle)

        #expect(games.map(\.appId) == [4_576_510, 1_245_620])
        #expect(games.map(\.name) == ["Casualties: Unknown Demo", "ELDEN RING"])
        // The duplicate App ID in the second library lost to the first discovery
        #expect(games[0].name != "Casualties Duplicate")
        // Downloading (999) and missing-install-dir (777) games are filtered
        #expect(!games.contains { $0.appId == 999 || $0.appId == 777 })
    }

    @Test("A second enumeration of an unchanged library returns the same games")
    func enumerationIsCachedUntilTheLibraryChanges() throws {
        let (bottle, tempRoot) = try makeFixtureBottle()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let first = SteamLibrary.enumerate(bottleURL: bottle)
        let second = SteamLibrary.enumerate(bottleURL: bottle)

        #expect(first.map(\.appId) == second.map(\.appId))
    }

    @Test("Installing a game invalidates the cache")
    func newManifestIsPickedUp() throws {
        let (bottle, tempRoot) = try makeFixtureBottle()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let before = SteamLibrary.enumerate(bottleURL: bottle)

        let steamapps = try #require(SteamLibrary.detectInstall(bottleURL: bottle))
            .appending(path: "steamapps")
        try FileManager.default.createDirectory(
            at: steamapps.appending(path: "common").appending(path: "New Game"),
            withIntermediateDirectories: true
        )
        try acf(appId: 271_590, name: "New Game", installDir: "New Game", stateFlags: 4)
            .write(
                to: steamapps.appending(path: "appmanifest_271590.acf"),
                atomically: true,
                encoding: .utf8
            )

        let after = SteamLibrary.enumerate(bottleURL: bottle)

        #expect(!before.contains { $0.appId == 271_590 })
        #expect(after.contains { $0.appId == 271_590 })
    }

    @Test("Runtime payloads are not listed as games")
    func filtersRuntimePayloads() throws {
        let (bottle, tempRoot) = try makeFixtureBottle()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let steamApps = bottle.appending(path: "drive_c")
            .appending(path: "Program Files (x86)").appending(path: "Steam")
            .appending(path: "steamapps")
        try FileManager.default.createDirectory(
            at: steamApps.appending(path: "common").appending(path: "Steamworks Shared"),
            withIntermediateDirectories: true
        )
        try Data(acf(
            appId: 228_980, name: "Steamworks Common Redistributables",
            installDir: "Steamworks Shared", stateFlags: 4
        ).utf8).write(to: steamApps.appending(path: "appmanifest_228980.acf"))

        let games = SteamLibrary.enumerate(bottleURL: bottle)

        #expect(!games.contains { $0.appId == 228_980 })
    }

    @Test("Collects executable names at root and one level deep")
    func collectsExecutableNames() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let bin = tempDir.appending(path: "bin")
        let deep = tempDir.appending(path: "bin").appending(path: "too-deep")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)

        try Data().write(to: tempDir.appending(path: "Game.exe"))
        try Data().write(to: tempDir.appending(path: "readme.txt"))
        try Data().write(to: bin.appending(path: "Helper.EXE"))
        try Data().write(to: deep.appending(path: "ignored.exe"))

        let names = SteamLibrary.executableNames(under: tempDir)

        #expect(names == ["game.exe", "helper.exe"])
    }

    @Test("Maps Windows paths through the prefix")
    func mapsWindowsPaths() {
        let bottle = URL(fileURLWithPath: "/tmp/bottle")

        let cPath = SteamLibrary.mapWindowsPath(#"C:\Program Files (x86)\Steam"#, bottleURL: bottle)
        #expect(cPath?.path == "/tmp/bottle/drive_c/Program Files (x86)/Steam")

        let dPath = SteamLibrary.mapWindowsPath(#"D:\SteamLibrary"#, bottleURL: bottle)
        #expect(dPath?.path == "/tmp/bottle/dosdevices/d:/SteamLibrary")

        let driveOnly = SteamLibrary.mapWindowsPath(#"D:\"#, bottleURL: bottle)
        #expect(driveOnly?.path == "/tmp/bottle/dosdevices/d:")

        #expect(SteamLibrary.mapWindowsPath("not a path", bottleURL: bottle) == nil)
        #expect(SteamLibrary.mapWindowsPath("", bottleURL: bottle) == nil)
    }

    @Test("Library paths that would escape the prefix are rejected")
    func rejectsTraversingLibraryPaths() {
        let bottle = URL(fileURLWithPath: "/tmp/bottle")

        #expect(SteamLibrary.mapWindowsPath(#"D:\..\..\..\etc"#, bottleURL: bottle) == nil)
        #expect(SteamLibrary.mapWindowsPath(#"C:\Steam\..\..\Library"#, bottleURL: bottle) == nil)
        #expect(SteamLibrary.mapWindowsPath(#"D:\Games\."#, bottleURL: bottle) == nil)
    }

    @Test("A manifest whose installdir escapes the library is skipped")
    func rejectsTraversingInstallDir() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let steamRoot = tempDir.appending(path: "drive_c").appending(path: "Program Files (x86)")
            .appending(path: "Steam")
        let steamApps = steamRoot.appending(path: "steamapps")
        try FileManager.default.createDirectory(at: steamApps, withIntermediateDirectories: true)
        try Data().write(to: steamRoot.appending(path: "steam.exe"))

        // The escape target exists, so only the component check can reject this.
        let outside = tempDir.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        try Data(acf(
            appId: 4_576_510, name: "Escaper", installDir: "../../../outside", stateFlags: 4
        ).utf8).write(to: steamApps.appending(path: "appmanifest_4576510.acf"))

        #expect(SteamLibrary.enumerate(bottleURL: tempDir).isEmpty)
    }

    @Test("Collects executable names and includes selectedURL")
    func collectsExecutableNamesWithSelectedURL() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let deep = tempDir.appending(path: "bin/sub/sub2")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)

        try Data().write(to: tempDir.appending(path: "Launcher.exe"))
        let selected = deep.appending(path: "ActualGame_shipping.exe")
        try Data().write(to: selected)

        let namesWithoutSelected = SteamLibrary.executableNames(under: tempDir)
        #expect(namesWithoutSelected == ["launcher.exe"])

        let namesWithSelected = SteamLibrary.executableNames(under: tempDir, selectedURL: selected)
        #expect(namesWithSelected.contains("launcher.exe"))
        #expect(namesWithSelected.contains("actualgame_shipping.exe"))
    }

    @Test("Caches library roots keyed by libraryfolders.vdf modification date")
    func libraryRootsCachingByModificationDate() throws {
        let (bottle, tempRoot) = try makeFixtureBottle()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let rootsFirst = SteamLibrary.libraryRoots(bottleURL: bottle)
        #expect(rootsFirst.count == 2)

        // Read again without modifying libraryfolders.vdf - hits cache
        let rootsSecond = SteamLibrary.libraryRoots(bottleURL: bottle)
        #expect(rootsSecond == rootsFirst)

        // Update libraryfolders.vdf with a 3rd library
        let steamRoot = bottle.appending(path: "drive_c")
            .appending(path: "Program Files (x86)").appending(path: "Steam")
        let config = steamRoot.appending(path: "config")
        let vdfPath = config.appending(path: "libraryfolders.vdf")

        let thirdLibrary = tempRoot.appending(path: "third-library")
        try FileManager.default.createDirectory(at: thirdLibrary, withIntermediateDirectories: true)
        let dosDevices = bottle.appending(path: "dosdevices")
        try FileManager.default.createSymbolicLink(
            at: dosDevices.appending(path: "e:"),
            withDestinationURL: thirdLibrary
        )

        let updatedVdf = """
        "libraryfolders"
        {
            "0"
            {
                "path"        "C:\\\\Program Files (x86)\\\\Steam"
            }
            "1"
            {
                "path"        "D:\\\\"
            }
            "2"
            {
                "path"        "E:\\\\"
            }
        }
        """
        try Data(updatedVdf.utf8).write(to: vdfPath)
        let futureDate = Date().addingTimeInterval(5)
        try FileManager.default.setAttributes([.modificationDate: futureDate], ofItemAtPath: vdfPath.path)

        let rootsThird = SteamLibrary.libraryRoots(bottleURL: bottle)
        #expect(rootsThird.count == 3)
    }

    @Test("Cached VDF paths discover a library after it becomes available")
    func availableVolumesAreCheckedOnEveryLookup() throws {
        let (bottle, tempRoot) = try makeFixtureBottle()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let secondary = tempRoot.appending(path: "second-library")
        #expect(SteamLibrary.libraryRoots(bottleURL: bottle).count == 2)
        try FileManager.default.removeItem(at: secondary)
        #expect(SteamLibrary.libraryRoots(bottleURL: bottle).count == 1)
        try FileManager.default.createDirectory(at: secondary, withIntermediateDirectories: true)
        #expect(SteamLibrary.libraryRoots(bottleURL: bottle).count == 2)
    }

    @Test("Retargeting a drive symlink invalidates enumeration with unchanged VDF and directory dates")
    func changedDriveMappingRefreshesEnumeratedGames() throws {
        let (bottle, tempRoot) = try makeFixtureBottle()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        #expect(SteamLibrary.enumerate(bottleURL: bottle).contains { $0.appId == 1_245_620 })
        let oldApps = tempRoot.appending(path: "second-library/steamapps")
        let date = try FileManager.default.attributesOfItem(atPath: oldApps.path)[.modificationDate] as? Date
        let replacement = tempRoot.appending(path: "replacement-library")
        let apps = replacement.appending(path: "steamapps")
        try FileManager.default.createDirectory(
            at: apps.appending(path: "common/Replacement"),
            withIntermediateDirectories: true
        )
        try acf(appId: 123, name: "Replacement", installDir: "Replacement", stateFlags: 4)
            .write(to: apps.appending(path: "appmanifest_123.acf"), atomically: true, encoding: .utf8)
        if let date {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: apps.path)
        }
        let link = bottle.appending(path: "dosdevices/d:")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: replacement)
        let games = SteamLibrary.enumerate(bottleURL: bottle)
        #expect(games.contains { $0.appId == 123 })
        #expect(!games.contains { $0.appId == 1_245_620 })
    }
}
