//
//  FolderDiscoveryTests.swift
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

@Suite("Portable folder discovery")
struct FolderDiscoveryTests {
    @Test func scanPreservesPersistedIdentitiesAndExcludesSteamAndLinks() throws {
        let bottle = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: bottle) }
        let games = bottle.appendingPathComponent("Games")
        for name in ["Title", "Hidden", "Steam"] {
            try FileManager.default.createDirectory(
                at: games.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createSymbolicLink(
            at: games.appendingPathComponent("Alias"),
            withDestinationURL: games.appendingPathComponent("Title")
        )
        var library = FolderGameLibrary()
        library.roots = ["Games"]
        library.excludedFolders = ["Games/Hidden"]
        try library.save(bottleURL: bottle)
        var loaded = try FolderGameLibrary.load(bottleURL: bottle)
        let entries = loaded.scan(bottleURL: bottle, steamDirectories: [games.appendingPathComponent("Steam")])
        #expect(entries.map(\.name) == ["Title"])
        #expect(entries.first?.metadataIdentity == "program:Games/Title")
        #expect(loaded.pendingMetadata == ["Games/Title"])
        var visibility = LibraryVisibility()
        try visibility.setHidden(true, for: #require(entries.first))
        try visibility.save(bottleURL: bottle)
        #expect(try LibraryVisibility.load(bottleURL: bottle).includes(entries[0]) == false)
        #expect(try LibraryVisibility.load(bottleURL: bottle).includes(entries[0], showHidden: true))
    }

    @Test func rootFolderIsNotEmittedAsGameWhenAlsoAssigned() throws {
        // The old per-row "游戏库" switch could put the same path in `roots`
        // and `assignedFolders`; a container of games must never become a
        // card named after the container itself (e.g. "~/codes/game").
        let bottle = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: bottle) }
        let games = bottle.appendingPathComponent("game")
        try FileManager.default.createDirectory(
            at: games.appendingPathComponent("Title"),
            withIntermediateDirectories: true
        )
        var library = FolderGameLibrary()
        library.roots = ["game"]
        library.assignedFolders = ["game"]
        let entries = library.scan(bottleURL: bottle, steamDirectories: [])
        #expect(entries.map(\.name) == ["Title"])
        #expect(!entries.contains { $0.metadataIdentity == "program:game" })
    }

    @Test func folderEntriesDetectLaunchersByNameAndExecutable() throws {
        let bottle = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: bottle) }
        let games = bottle.appendingPathComponent("Games")
        for name in ["Epic Games", "Plain Game", "Steam Folder"] {
            try FileManager.default.createDirectory(
                at: games.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        var library = FolderGameLibrary()
        library.roots = ["Games"]
        library.executables["Games/Plain Game"] = "Games/Plain Game/steam.exe"
        library.executables["Games/Steam Folder"] = "Games/Steam Folder/game.exe"
        let entries = library.scan(bottleURL: bottle, steamDirectories: [])
        // The folder name alone is enough for the store-directory heuristic.
        #expect(entries.first { $0.name == "Epic Games" }?.launcher == .epicGames)
        // A chosen executable classifies the folder too.
        #expect(entries.first { $0.name == "Plain Game" }?.launcher == .steam)
        // A folder merely named like a client is not one once the user picked
        // an executable that says otherwise.
        #expect(entries.first { $0.name == "Steam Folder" }?.launcher == nil)
    }

    @Test func launcherSettingsPersistIdentitiesPerBottle() throws {
        let bottle = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: bottle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bottle) }
        let entry = LibraryEntry(
            id: "steam-client:test", name: "Steam", iconURL: nil,
            bottleURL: bottle, source: .steam,
            launch: .program(bottle.appendingPathComponent("drive_c/Steam/steam.exe")),
            launcher: .steam
        )
        var settings = LauncherSettings()
        settings.setAutoStart(true, for: entry)
        try settings.save(bottleURL: bottle)
        var loaded = try LauncherSettings.load(bottleURL: bottle)
        #expect(loaded.autoStart == ["program:drive_c/Steam/steam.exe"])
        loaded.setAutoStart(false, for: entry)
        #expect(loaded.autoStart.isEmpty)
    }

    @Test func oldSchemaAndOfflineRootsKeepKnownGames() throws {
        var library = try JSONDecoder().decode(
            FolderGameLibrary.self,
            from: Data(#"{"roots":["Offline"],"knownFolders":["Offline/Title"]}"#.utf8)
        )
        let bottle = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(library.initializedRoots == ["Offline"])
        var failures = 0
        let entries = library.scan(bottleURL: bottle, steamDirectories: []) { _, _ in failures += 1 }
        #expect(failures == 1)
        #expect(entries.count == 1)
        #expect(entries.first?.metadataIdentity == "program:Offline/Title")
        library.roots = []
        #expect(library.scan(bottleURL: bottle, steamDirectories: []).isEmpty)
    }
}
