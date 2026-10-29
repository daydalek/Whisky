//
//  LibraryPresentationTests.swift
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

@Suite("Portable library presentation storage")
struct LibraryPresentationTests {
    @Test func storageKeysMatchSHA256Vectors() {
        #expect(LibraryStorageLayout.key("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(LibraryStorageLayout.key("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(LibraryStorageLayout.key("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
            == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        #expect(LibraryStorageLayout.key(String(repeating: "a", count: 1_000_000))
            == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test func missingSnapshotsPreserveTheContainer() throws {
        let entry = fixtureEntry()
        let result = try LibraryPresentation.load(for: entry)
        #expect(result.metadata == nil)
        #expect(result.activity == GameActivity())
        #expect(!FileManager.default.fileExists(atPath: entry.bottleURL.path))
    }

    @Test func existingMetadataActivityAndCustomCoverShareTheNativeLayout() throws {
        let entry = fixtureEntry()
        defer { try? FileManager.default.removeItem(at: entry.bottleURL) }
        let metadata = GameMetadata(
            source: .vndb,
            sourceID: "v42",
            title: "Title",
            developer: "Studio",
            coverURL: URL(string: "https://example.com/cover.png")
        )
        try write(JSONEncoder().encode(metadata), at: LibraryStorageLayout.metadata(for: entry))
        var activity = GameActivity()
        activity.playTime = 3_600
        activity.rating = 9
        activity.lastSessionEndedAt = Date(timeIntervalSince1970: 1_234)
        try write(JSONEncoder().encode(activity), at: LibraryStorageLayout.activity(for: entry))
        let name = UUID().uuidString
        let settings = Data("{\"useCustomCover\":true,\"customFileName\":\"\(name)\"}".utf8)
        try write(settings, at: LibraryStorageLayout.metadata(for: entry).appendingPathExtension("cover-settings"))
        let cover = entry.metadataDirectory.appendingPathComponent("Custom Covers/\(name)")
        try write(Data([1, 2, 3]), at: cover)
        let before = try Data(contentsOf: LibraryStorageLayout.metadata(for: entry))
        let result = try LibraryPresentation.load(for: entry)
        #expect(result.metadata == GameMetadataRecord(legacy: metadata).resolved().metadata)
        #expect(result.metadata?.provenance?["basic"]?.sourceID == "v42")
        #expect(result.activity == activity)
        #expect(result.coverURL == cover)
        #expect(try Data(contentsOf: LibraryStorageLayout.metadata(for: entry)) == before)
    }

    @Test func customCoverTraversalAndCorruptSnapshotsRemainVisibleErrors() throws {
        let entry = fixtureEntry()
        defer { try? FileManager.default.removeItem(at: entry.bottleURL) }
        let settings = Data(#"{"useCustomCover":true,"customFileName":"../../private.png"}"#.utf8)
        try write(settings, at: LibraryStorageLayout.metadata(for: entry).appendingPathExtension("cover-settings"))
        #expect(try LibraryPresentation.load(for: entry).coverURL == nil)
        let corrupt = Data("invalid".utf8)
        try write(corrupt, at: LibraryStorageLayout.metadata(for: entry))
        #expect(throws: (any Error).self) { try LibraryPresentation.load(for: entry) }
        #expect(try Data(contentsOf: LibraryStorageLayout.metadata(for: entry)) == corrupt)
    }

    private func fixtureEntry() -> LibraryEntry {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return LibraryEntry(
            id: "game",
            name: "Game",
            iconURL: nil,
            bottleURL: root,
            source: .folder,
            launch: .program(root.appendingPathComponent("Games/游戏"))
        )
    }

    private func write(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
