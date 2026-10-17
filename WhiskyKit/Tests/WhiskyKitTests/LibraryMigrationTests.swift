//
//  LibraryMigrationTests.swift
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

@Suite("Library migration regressions")
struct LibraryMigrationTests {
    private func fixture() throws -> URL {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for path in ["A", "B", "C", "Games/Title", "Games/Unlinked"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(path), withIntermediateDirectories: true
            )
        }
        return root
    }

    @Test @MainActor func settingsAreCopiedBeforeCreatingTargetProgram() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = Bottle(bottleUrl: root.appendingPathComponent("A"))
        let target = Bottle(bottleUrl: root.appendingPathComponent("B"))
        let executable = root.appendingPathComponent("Games/Title/play.exe")
        let original = Program(url: executable, bottle: source, peFile: nil)
        original.settings.locale = .japanese
        original.settings.environment = ["CUSTOM_SETTING": "saved"]
        original.settings.arguments = "-windowed"

        FolderGameLibrary.migrateProgramSettings(for: executable, from: source.url, to: target.url)
        let moved = Program(url: executable, bottle: target, peFile: nil)
        #expect(moved.settings.locale == .japanese)
        #expect(moved.settings.environment == original.settings.environment)
        #expect(moved.settings.arguments == "-windowed")

        moved.settings.locale = .chineseSimplified
        FolderGameLibrary.migrateProgramSettings(for: executable, from: source.url, to: target.url)
        let reloaded = Program(url: executable, bottle: target, peFile: nil)
        #expect(reloaded.settings.locale == .chineseSimplified)
    }

    @Test func rootMovePreservesMetadataCoverAndManualUnlink() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("A")
        let target = root.appendingPathComponent("B")
        // A bottle-relative root exercises identity conversion to an absolute path.
        let games = source.appendingPathComponent("Games")
        for name in ["Title", "Unlinked"] {
            try FileManager.default.createDirectory(
                at: games.appendingPathComponent(name), withIntermediateDirectories: true
            )
        }
        var library = FolderGameLibrary()
        library.roots = ["Games"]
        let entries = library.scan(bottleURL: source, steamDirectories: [])
        library.pendingMetadata.removeAll()
        try library.save(bottleURL: source)
        let title = try #require(entries.first { $0.name == "Title" })
        let unlinked = try #require(entries.first { $0.name == "Unlinked" })
        let store = GameMetadataStore(directory: title.metadataDirectory)
        let cover = try #require(URL(string: "https://example.invalid/cover.jpg"))
        let metadata = GameMetadata(source: .vndb, sourceID: "v1", title: "Chosen", coverURL: cover)
        try await store.save(metadata, for: title.metadataIdentity)
        try await store.remove(for: unlinked.metadataIdentity)
        let coverFile = store.coverLocation(for: cover)
        try FileManager.default.createDirectory(
            at: coverFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let coverData = Data("cached cover".utf8)
        try coverData.write(to: coverFile)

        try await FolderGameLibrary.moveRoot("Games", from: source, to: target)

        var moved = try FolderGameLibrary.load(bottleURL: target)
        let movedEntries = moved.scan(bottleURL: target, steamDirectories: [])
        let movedTitle = try #require(movedEntries.first { $0.name == "Title" })
        let movedUnlinked = try #require(movedEntries.first { $0.name == "Unlinked" })
        let targetStore = GameMetadataStore(directory: movedTitle.metadataDirectory)
        #expect(try await targetStore.load(for: movedTitle.metadataIdentity) == metadata)
        #expect(try Data(contentsOf: targetStore.coverLocation(for: cover)) == coverData)
        #expect(try await targetStore.allowsAutomaticMatch(for: movedUnlinked.metadataIdentity) == false)
        #expect(moved.pendingMetadata.isEmpty)
    }

    @Test func rootMoveKeepsPreviouslyMovedGamesExcluded() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("A")
        let target = root.appendingPathComponent("B")
        let other = root.appendingPathComponent("C")
        let games = source.appendingPathComponent("Games")
        for name in ["Title", "Remaining"] {
            try FileManager.default.createDirectory(
                at: games.appendingPathComponent(name), withIntermediateDirectories: true
            )
        }
        var library = FolderGameLibrary()
        library.roots = ["Games"]
        _ = library.scan(bottleURL: source, steamDirectories: [])
        // An exclusion for another root stays with the source bottle.
        library.excludedFolders.insert("Other/Excluded")
        try library.save(bottleURL: source)
        let title = games.appendingPathComponent("Title")
        try FolderGameLibrary.moveFolder(title, from: source, to: other)

        try await FolderGameLibrary.moveRoot("Games", from: source, to: target)

        var moved = try FolderGameLibrary.load(bottleURL: target)
        var assigned = try FolderGameLibrary.load(bottleURL: other)
        let original = try FolderGameLibrary.load(bottleURL: source)
        #expect(moved.scan(bottleURL: target, steamDirectories: []).map(\.name) == ["Remaining"])
        #expect(assigned.scan(bottleURL: other, steamDirectories: []).map(\.name) == ["Title"])
        #expect(moved.excludedFolders.contains(title.path))
        #expect(original.excludedFolders == ["Other/Excluded"])
    }
}
