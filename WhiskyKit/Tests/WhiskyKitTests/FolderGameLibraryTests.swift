// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import WhiskyKit

@Suite("Folder game discovery")
struct FolderGameLibraryTests {
    @Test func onlyFirstRootScanQueuesAutomaticMetadata() throws {
        let bottle = try fixture()
        defer { try? FileManager.default.removeItem(at: bottle) }
        let root = bottle.appendingPathComponent("Games")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("First"), withIntermediateDirectories: true)
        var library = FolderGameLibrary()
        library.roots = ["Games"]
        _ = library.scan(bottleURL: bottle, steamDirectories: [])
        #expect(library.pendingMetadata == ["Games/First"])
        library.pendingMetadata.removeAll()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Second"), withIntermediateDirectories: true)
        #expect(library.scan(bottleURL: bottle, steamDirectories: []).count == 2)
        #expect(library.pendingMetadata.isEmpty)
        try library.save(bottleURL: bottle)
        library = try FolderGameLibrary.load(bottleURL: bottle)
        _ = library.scan(bottleURL: bottle, steamDirectories: [])
        #expect(library.pendingMetadata.isEmpty)
    }

    @Test func legacySettingsDoNotAutomaticallyRescrapeExistingRoots() throws {
        let data = Data(#"{"roots":["Games"],"executables":{},"knownFolders":[],"automaticMetadata":true}"#.utf8)
        let library = try JSONDecoder().decode(FolderGameLibrary.self, from: data)
        #expect(library.initializedRoots == ["Games"])
        #expect(library.pendingMetadata.isEmpty)
    }

    @Test func removedEntriesRemainHiddenWithoutDeletingGameFiles() throws {
        let bottle = try fixture()
        defer { try? FileManager.default.removeItem(at: bottle) }
        let folder = bottle.appendingPathComponent("Games/Title")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var library = FolderGameLibrary()
        library.roots = ["Games"]
        let entry = try #require(library.scan(bottleURL: bottle, steamDirectories: []).first)
        var visibility = LibraryVisibility()
        visibility.hiddenIdentities.insert(entry.metadataIdentity)
        try visibility.save(bottleURL: bottle)
        visibility = try LibraryVisibility.load(bottleURL: bottle)
        #expect(!visibility.includes(entry))
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(library.scan(bottleURL: bottle, steamDirectories: []).filter(visibility.includes).isEmpty)
    }

    private func fixture() throws -> URL {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func directFoldersDoNotRequireExecutables() throws {
        let bottle = try fixture()
        defer { try? FileManager.default.removeItem(at: bottle) }
        let games = bottle.appendingPathComponent("drive_c/Games")
        for name in ["Game One", "Game Two/data", ".hidden"] {
            try FileManager.default.createDirectory(at: games.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data().write(to: games.appendingPathComponent("installer.exe"))
        try FileManager.default.createSymbolicLink(at: games.appendingPathComponent("alias"),
                                                   withDestinationURL: games.appendingPathComponent("Game One"))
        var library = FolderGameLibrary()
        library.roots = ["drive_c/Games"]
        let entries = library.scan(bottleURL: bottle, steamDirectories: [])
        #expect(Set(entries.map(\.name)) == ["Game One", "Game Two"])
        #expect(entries.allSatisfy { $0.source == .folder && $0.iconURL == nil })
    }

    @Test func selectedExecutableDoesNotChangeIdentity() throws {
        let bottle = try fixture()
        defer { try? FileManager.default.removeItem(at: bottle) }
        let folder = bottle.appendingPathComponent("Games/Title")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var library = FolderGameLibrary()
        library.roots = ["Games"]
        let before = try #require(library.scan(bottleURL: bottle, steamDirectories: []).first)
        library.executables["Games/Title"] = "Games/Title/bin/start.exe"
        try library.save(bottleURL: bottle)
        library = try FolderGameLibrary.load(bottleURL: bottle)
        let after = try #require(library.scan(bottleURL: bottle, steamDirectories: []).first)
        #expect(before.id == after.id)
        #expect(before.metadataIdentity == after.metadataIdentity)
        #expect(library.executable(for: folder, bottleURL: bottle)?.lastPathComponent == "start.exe")
        #expect(library.executables["Games/Title"] == "Games/Title/bin/start.exe")
    }

    @Test func steamInstallAndGameDirectoriesAreExcluded() throws {
        let bottle = try fixture()
        defer { try? FileManager.default.removeItem(at: bottle) }
        let steam = bottle.appendingPathComponent("Games/Steam")
        let game = bottle.appendingPathComponent("Games/SteamGame")
        for url in [steam, game, bottle.appendingPathComponent("Games/LocalGame")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        var library = FolderGameLibrary()
        library.roots = ["Games", "Games"]
        #expect(library.scan(bottleURL: bottle, steamDirectories: [steam, game]).map(\.name) == ["LocalGame"])
    }

    @Test func unavailableRootKeepsEntriesButRemovingRootDoesNot() throws {
        let bottle = try fixture()
        defer { try? FileManager.default.removeItem(at: bottle) }
        var library = FolderGameLibrary()
        library.roots = ["Unavailable"]
        library.knownFolders = ["Unavailable/Title"]
        #expect(library.scan(bottleURL: bottle, steamDirectories: []).count == 1)
        library.roots = []
        #expect(library.scan(bottleURL: bottle, steamDirectories: []).isEmpty)
    }

    @Test func nameCleanupRetainsSubtitles() {
        #expect(FolderGameMatching.query("星之终途 汉化版 v1.2") == "星之终途")
        #expect(FolderGameMatching.query("Game (Another Story)") == "Game (Another Story)")
        #expect(FolderGameMatching.query("[测试汉化组] 夏日物语 官方中文版 v1.2") == "夏日物语")
        #expect(FolderGameMatching.query("[Another Story] Game") == "[Another Story] Game")
        #expect(FolderGameMatching.normalized("ＧＡＭＥ: One") == "gameone")
    }

    @Test func onlyUniqueExactNamesAreAutomaticallyMatched() {
        let exact = GameMetadata(source: .bangumi, sourceID: "1", title: "Game")
        let other = GameMetadata(source: .bangumi, sourceID: "2", title: "Game 2")
        let result = GameMetadataSearchResult(source: .bangumi, games: [exact, other], error: nil)
        #expect(FolderGameMatching.candidate(query: "game", results: [result], sources: [.bangumi]) == exact)
        #expect(FolderGameMatching.candidate(query: "gam", results: [result], sources: [.bangumi]) == nil)
        let duplicate = GameMetadataSearchResult(source: .bangumi, games: [exact, exact], error: nil)
        #expect(FolderGameMatching.candidate(query: "Game", results: [duplicate], sources: [.bangumi]) == nil)
    }

    @Test func matchesEveryAliasAndTraditionalChinese() {
        let game = GameMetadata(source: .vndb, sourceID: "v1", title: "Romanized",
                                originalTitle: "日本語", alternateTitles: ["夏日物語", "Summer Tale"])
        let results = [GameMetadataSearchResult(source: .vndb, games: [game], error: nil)]
        for query in ["夏日物语", "Summer Tale", "日本語", "Romanized"] {
            #expect(FolderGameMatching.candidate(query: query, results: results, sources: [.vndb]) == game)
        }
    }

    @Test func longTypoMatchesWhileCloseAlternativesAndEditionsRequireConfirmation() {
        let title = "A Wonderful Summer Story"
        let game = GameMetadata(source: .vndb, sourceID: "v1", title: title)
        func candidate(_ query: String, games: [GameMetadata] = []) -> GameMetadata? {
            FolderGameMatching.candidate(query: query, results: [
                GameMetadataSearchResult(source: .vndb, games: games.isEmpty ? [game] : games, error: nil)
            ], sources: [.vndb])
        }
        #expect(candidate("A Wonderfull Summer Story") == game)
        for query in [title + " 2", title + " II", title + " FD", title + "+", title + " Complete"] {
            #expect(candidate(query) == nil, "Edition query: \(query)")
        }
        let close = GameMetadata(source: .vndb, sourceID: "v2", title: "A Wonderful Summer Stori")
        #expect(candidate("A Wonderfull Summer Story", games: [close, game]) == nil)
        #expect(FolderGameMatching.ranked(query: title, games: [close, game]).first == game)
    }

    @Test func exactLaterSourceWinsAndFailedSourcesAllowFallback() {
        let close = GameMetadata(source: .bangumi, sourceID: "1", title: "A Wonderfull Summer Story")
        let exact = GameMetadata(source: .vndb, sourceID: "v1", title: "A Wonderful Summer Story")
        for error in [nil, "HTTP 500"] {
            let results = [
                GameMetadataSearchResult(source: .bangumi, games: [close], error: error),
                GameMetadataSearchResult(source: .vndb, games: [exact], error: nil)
            ]
            #expect(FolderGameMatching.candidate(query: exact.title, results: results,
                                                sources: [.bangumi, .vndb]) == exact)
        }
    }

    @Test func manualUnlinkPreventsAutomaticRelinking() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GameMetadataStore(directory: root)
        let metadata = GameMetadata(source: .bangumi, sourceID: "1", title: "Game")
        try await store.saveAutomatic(metadata, for: "folder")
        #expect(try await store.load(for: "folder") == metadata)
        try await store.remove(for: "folder")
        try await store.saveAutomatic(metadata, for: "folder")
        #expect(try await store.load(for: "folder") == nil)
        try await store.save(metadata, for: "folder")
        #expect(try await store.load(for: "folder") == metadata)
    }

    @Test func automaticMatchNeverOverwritesManualMetadata() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GameMetadataStore(directory: root)
        let chosen = GameMetadata(source: .vndb, sourceID: "v1", title: "Chosen")
        try await store.save(chosen, for: "folder")
        let other = GameMetadata(source: .bangumi, sourceID: "2", title: "Other")
        try await GameMetadataStore(directory: root).saveAutomatic(other, for: "folder")
        #expect(try await store.load(for: "folder") == chosen)
    }

    @Test func externalRootsAndBottleRelativePathsRoundTrip() throws {
        let bottle = URL(fileURLWithPath: "/Library/TestBottle")
        let relative = bottle.appendingPathComponent("drive_c/Games/Title")
        #expect(FolderGameLibrary.key(for: relative, bottleURL: bottle) == "drive_c/Games/Title")
        let moved = URL(fileURLWithPath: "/Volumes/Other/TestBottle")
        #expect(FolderGameLibrary.url(for: "drive_c/Games/Title", bottleURL: moved).path
                == "/Volumes/Other/TestBottle/drive_c/Games/Title")
        let external = URL(fileURLWithPath: "/Volumes/Games/Title")
        #expect(FolderGameLibrary.url(for: FolderGameLibrary.key(for: external, bottleURL: bottle),
                                    bottleURL: moved).path == external.path)
    }
}
