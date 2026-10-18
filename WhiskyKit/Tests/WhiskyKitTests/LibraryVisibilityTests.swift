//
//  LibraryVisibilityTests.swift
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

@Suite("Library visibility")
struct LibraryVisibilityTests {
    private func entry(bottle: URL, id: Int, source: LibrarySourceID = .folder) -> LibraryEntry {
        let url = bottle.appendingPathComponent("Games/Game\(id)/Launch.exe")
        return LibraryEntry(
            id: url.path,
            name: "Game \(id)",
            iconURL: url,
            bottleURL: bottle,
            source: source,
            launch: .program(url)
        )
    }

    @Test func hidingIsPersistentReversibleAndKeepsFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let game = entry(bottle: root, id: 1)
        guard case let .program(executable) = game.launch else { return }
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = Data("game bytes".utf8)
        try original.write(to: executable)
        var visibility = try LibraryVisibility.load(bottleURL: root)
        #expect(visibility.includes(game))
        visibility.setHidden(true, for: game)
        try visibility.save(bottleURL: root)
        visibility = try LibraryVisibility.load(bottleURL: root)
        #expect(visibility.isHidden(game))
        #expect(!visibility.includes(game))
        #expect(visibility.includes(game, showHidden: true))
        #expect(visibility.includes(entry(bottle: root, id: 2)))
        #expect(try Data(contentsOf: executable) == original)
        visibility.setHidden(false, for: game)
        try visibility.save(bottleURL: root)
        let restored = try LibraryVisibility.load(bottleURL: root)
        #expect(restored.includes(game))
        #expect(!restored.isHidden(game))
        #expect(try Data(contentsOf: executable) == original)
    }

    @Test func showAllKeepsSourcePreferencesAndLegacyMarkers() throws {
        let root = URL(fileURLWithPath: "/tmp/bottle")
        let folder = entry(bottle: root, id: 1)
        let pinned = entry(bottle: root, id: 2, source: .pinned)
        let legacy = try JSONSerialization.data(withJSONObject: [
            "hiddenIdentities": [folder.metadataIdentity], "includePinnedAndSteam": true
        ])
        var visibility = try JSONDecoder().decode(LibraryVisibility.self, from: legacy)
        #expect(visibility.isHidden(folder))
        #expect(visibility.includes(folder, showHidden: true))
        visibility.includePinnedAndSteam = false
        #expect(visibility.includes(folder, showHidden: true))
        #expect(!visibility.includes(pinned, showHidden: true))
        visibility.setHidden(true, for: pinned)
        #expect(!visibility.includes(pinned, showHidden: true))
    }

    @Test func identitiesSurviveBottleRelocationAndSeparateStores() throws {
        let first = URL(fileURLWithPath: "/old/bottle")
        let second = URL(fileURLWithPath: "/new/bottle")
        let game = entry(bottle: first, id: 1)
        var visibility = LibraryVisibility()
        visibility.setHidden(true, for: game)
        let relocated = entry(bottle: second, id: 1)
        #expect(visibility.isHidden(relocated))
        #expect(!visibility.isHidden(entry(bottle: second, id: 2)))
        #expect(!LibraryVisibility().isHidden(relocated))
    }
}
