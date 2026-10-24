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
