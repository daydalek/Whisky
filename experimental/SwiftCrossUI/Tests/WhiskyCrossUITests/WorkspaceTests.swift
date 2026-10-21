//
//  WorkspaceTests.swift
//  WhiskyCrossUI
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
import WhiskyCore
@testable import WhiskyCrossUI
#if os(macOS)
import CryptoKit
import WhiskyKit
#endif

@Suite("SwiftCrossUI real workspace")
struct WorkspaceTests {
    @Test func registryDiscoveryReadsRealMetadataAndPreservesFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = root.appendingPathComponent("Bottle")
        try FileManager.default.createDirectory(
            at: bottle.appendingPathComponent("Games/Folder"),
            withIntermediateDirectories: true
        )
        var folders = FolderGameLibrary()
        folders.roots = ["Games"]
        try folders.save(bottleURL: bottle)
        let entry = try #require(readBrowserEntries(root: nil, bottle: bottle).first)
        let metadata = GameMetadata(source: .bangumi, sourceID: "42", title: "中文标题", alternateTitles: ["Alias"])
        let file = LibraryStorageLayout.metadata(for: entry)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(metadata).write(to: file)
        let registry = root.appendingPathComponent("registry.plist")
        struct Registry: Encodable { let paths: [URL] }
        try PropertyListEncoder().encode(Registry(paths: [bottle, bottle])).write(to: registry)
        let before = try Data(contentsOf: registry)
        let result = try WorkspaceSnapshot.load(arguments: ["app", "--registry", registry.path])
        #expect(result.containers.count == 1)
        #expect(result.games.count == 1)
        #expect(result.games.first?.title == "中文标题")
        #expect(result.warnings.isEmpty)
        #expect(try Data(contentsOf: registry) == before)
        #expect(!FileManager.default.fileExists(atPath: bottle.appendingPathComponent("Metadata.plist").path))
        var state = WorkspaceState()
        state.snapshot = result
        state.query = "alias"
        #expect(state.games.count == 1)
    }

    @Test func corruptRegistryIsReportedAndPreserved() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let data = Data("corrupt registry".utf8)
        try data.write(to: file)
        #expect(throws: (any Error).self) { try WorkspaceSnapshot.load(arguments: ["app", "--registry", file.path]) }
        #expect(try Data(contentsOf: file) == data)
    }

    @Test func detailEditsPreserveActivityOwnershipAndOtherVisibilityChoices() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = LibraryEntry(
            id: "pin",
            name: "Pin",
            iconURL: nil,
            bottleURL: root,
            source: .pinned,
            launch: .program(root.appendingPathComponent("pin.exe"))
        )
        var activity = GameActivity()
        activity.playTime = 4_321
        activity.owner = GameActivityOwner(source: .worker, process: HostProcessIdentity(pid: 123, birth: 456))
        activity.lastAppliedSample = try GameActivitySampleToken(
            ownerID: #require(activity.owner?.ownerID),
            generation: 3,
            sequence: 5
        )
        let file = LibraryStorageLayout.activity(for: entry)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(activity).write(to: file)
        var visibility = LibraryVisibility()
        visibility.hiddenIdentities.insert("steam:other")
        try visibility.save(bottleURL: root)
        let edits = WorkspaceEdits()
        try await edits.setRating(8, for: entry)
        let saved = try JSONDecoder().decode(GameActivity.self, from: Data(contentsOf: file))
        #expect(saved.rating == 8)
        #expect(saved.owner == activity.owner)
        #expect(saved.lastAppliedSample == activity.lastAppliedSample)
        #expect(saved.playTime == 4_321)
        await #expect(throws: (any Error).self) { try await edits.setRating(11, for: entry) }
        #expect(try JSONDecoder().decode(GameActivity.self, from: Data(contentsOf: file)) == saved)
        try await edits.setHidden(true, for: entry)
        #expect(try LibraryVisibility.load(bottleURL: root).hiddenIdentities == ["steam:other", entry.metadataIdentity])
        try await edits.setHidden(false, for: entry)
        #expect(try LibraryVisibility.load(bottleURL: root).hiddenIdentities == ["steam:other"])
    }

    #if os(macOS)
    @Test func portableStorageReadsTheProductionStoreAndCryptoKitKeys() async throws {
        for value in ["", "program:Games/游戏", String(repeating: "é", count: 128), "steam:42"] {
            let expected = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
            #expect(LibraryStorageLayout.key(value) == expected)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = LibraryEntry(
            id: "pin",
            name: "Pin",
            iconURL: nil,
            bottleURL: root,
            source: .pinned,
            launch: .program(root.appendingPathComponent("pin.exe"))
        )
        let metadata = GameMetadata(source: .steam, sourceID: "42", title: "Real store")
        try await GameMetadataStore(directory: entry.metadataDirectory).save(metadata, for: entry.metadataIdentity)
        try GameActivityStore.shared.setRating(7, for: entry)
        let result = try LibraryPresentation.load(for: entry)
        #expect(result.metadata == metadata)
        #expect(result.activity.rating == 7)
    }
    #endif
}
