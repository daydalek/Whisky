//
//  FolderGameLibraryTests.swift
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

@Suite("Folder game discovery")
// swiftlint:disable:next type_body_length
struct FolderGameLibraryTests {
    @Test func onlyFirstRootScanQueuesAutomaticMetadata() throws {
        let bottle = try fixture()
        defer { try? FileManager.default.removeItem(at: bottle) }
        let root = bottle.appendingPathComponent("Games")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("First"),
            withIntermediateDirectories: true
        )
        var library = FolderGameLibrary()
        library.roots = ["Games"]
        _ = library.scan(bottleURL: bottle, steamDirectories: [])
        #expect(library.pendingMetadata == ["Games/First"])
        library.pendingMetadata.removeAll()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Second"),
            withIntermediateDirectories: true
        )
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
            try FileManager.default.createDirectory(
                at: games.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        try Data().write(to: games.appendingPathComponent("installer.exe"))
        try FileManager.default.createSymbolicLink(
            at: games.appendingPathComponent("alias"),
            withDestinationURL: games.appendingPathComponent("Game One")
        )
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
        #expect(FolderGameMatching.query("[230526][新新汉化] 苍之彼方的四重奏 免安装绿色版 Ver1.02 [CHS]") == "苍之彼方的四重奏")
        #expect(FolderGameMatching.query("Game 2 Build 1024") == "Game 2")
        #expect(FolderGameMatching.query("[Another Story] Game") == "[Another Story] Game")
        #expect(FolderGameMatching.normalized("ＧＡＭＥ: One") == "gameone")
        #expect(FolderGameMatching.normalized("櫻之詩 桜の詩") == "樱之诗樱の诗")
    }

    @Test func canonicalEditionsAndShinjitaiMatchAcrossSources() {
        let sequel = GameMetadata(source: .vndb, sourceID: "v2", title: "WHITE ALBUM 2")
        let remake = GameMetadata(source: .bangumi, sourceID: "10", title: "Summer Story Remake")
        let results = [
            GameMetadataSearchResult(source: .vndb, games: [sequel], error: nil),
            GameMetadataSearchResult(source: .bangumi, games: [remake], error: nil)
        ]
        #expect(FolderGameMatching.candidate(
            query: "White Album II", results: results, sources: [.vndb, .bangumi]
        ) == sequel)
        #expect(FolderGameMatching.candidate(
            query: "Summer Story 重制版", results: results, sources: [.vndb, .bangumi]
        ) == remake)
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
        let game = GameMetadata(
            source: .vndb,
            sourceID: "v1",
            title: "Romanized",
            originalTitle: "日本語",
            alternateTitles: ["夏日物語", "Summer Tale"]
        )
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
            #expect(FolderGameMatching.candidate(
                query: exact.title,
                results: results,
                sources: [.bangumi, .vndb]
            ) == exact)
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

    @Test func externalRootsAndBottleRelativePathsRoundTrip() {
        let bottle = URL(fileURLWithPath: "/Library/TestBottle")
        let relative = bottle.appendingPathComponent("drive_c/Games/Title")
        #expect(FolderGameLibrary.key(for: relative, bottleURL: bottle) == "drive_c/Games/Title")
        let moved = URL(fileURLWithPath: "/Volumes/Other/TestBottle")
        #expect(FolderGameLibrary.url(for: "drive_c/Games/Title", bottleURL: moved).path
            == "/Volumes/Other/TestBottle/drive_c/Games/Title")
        let external = URL(fileURLWithPath: "/Volumes/Games/Title")
        #expect(FolderGameLibrary.url(
            for: FolderGameLibrary.key(for: external, bottleURL: bottle),
            bottleURL: moved
        ).path == external.path)
    }

    @Test func movingSingleFolderGameReassignsBottleAndPreservesExecutable() throws {
        let bottleA = try fixture()
        let bottleB = try fixture()
        defer {
            try? FileManager.default.removeItem(at: bottleA)
            try? FileManager.default.removeItem(at: bottleB)
        }
        let root = bottleA.appendingPathComponent("Games")
        let gameOne = root.appendingPathComponent("GameOne")
        let gameTwo = root.appendingPathComponent("GameTwo")
        let exeURL = gameOne.appendingPathComponent("bin/play.exe")
        for dir in [gameOne.appendingPathComponent("bin"), gameTwo] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data().write(to: exeURL)

        var libA = FolderGameLibrary()
        libA.roots = ["Games"]
        _ = libA.scan(bottleURL: bottleA, steamDirectories: [])
        libA.executables["Games/GameOne"] = "Games/GameOne/bin/play.exe"
        try libA.save(bottleURL: bottleA)

        try FolderGameLibrary.moveFolder(gameOne, from: bottleA, to: bottleB)

        var reloadedA = try FolderGameLibrary.load(bottleURL: bottleA)
        let entriesA = reloadedA.scan(bottleURL: bottleA, steamDirectories: [])
        #expect(entriesA.map(\.name) == ["GameTwo"])

        var reloadedB = try FolderGameLibrary.load(bottleURL: bottleB)
        let entriesB = reloadedB.scan(bottleURL: bottleB, steamDirectories: [])
        #expect(entriesB.map(\.name) == ["GameOne"])
        #expect(entriesB.first?.bottleURL == bottleB)
        #expect(reloadedB.executable(for: gameOne, bottleURL: bottleB)?.standardizedFileURL == exeURL
            .standardizedFileURL)
    }

    @Test func movingRootReassignsAllGamesUnderRootBetweenBottles() async throws {
        let bottleA = try fixture()
        let bottleB = try fixture()
        defer {
            try? FileManager.default.removeItem(at: bottleA)
            try? FileManager.default.removeItem(at: bottleB)
        }
        let externalRoot = try fixture()
        defer { try? FileManager.default.removeItem(at: externalRoot) }
        let gameOne = externalRoot.appendingPathComponent("GameOne")
        let exeURL = gameOne.appendingPathComponent("start.exe")
        try FileManager.default.createDirectory(at: gameOne, withIntermediateDirectories: true)
        try Data().write(to: exeURL)

        var libA = FolderGameLibrary()
        let rootKey = FolderGameLibrary.key(for: externalRoot, bottleURL: bottleA)
        libA.roots = [rootKey]
        _ = libA.scan(bottleURL: bottleA, steamDirectories: [])
        let gameKeyA = FolderGameLibrary.key(for: gameOne, bottleURL: bottleA)
        libA.executables[gameKeyA] = FolderGameLibrary.key(for: exeURL, bottleURL: bottleA)
        try libA.save(bottleURL: bottleA)

        try await FolderGameLibrary.moveRoot(rootKey, from: bottleA, to: bottleB)

        var reloadedA = try FolderGameLibrary.load(bottleURL: bottleA)
        #expect(reloadedA.scan(bottleURL: bottleA, steamDirectories: []).isEmpty)

        var reloadedB = try FolderGameLibrary.load(bottleURL: bottleB)
        let entriesB = reloadedB.scan(bottleURL: bottleB, steamDirectories: [])
        #expect(entriesB.map(\.name) == ["GameOne"])
        #expect(reloadedB.executable(for: gameOne, bottleURL: bottleB)?.standardizedFileURL == exeURL
            .standardizedFileURL)
    }

    @Test func metadataStoreCopiesSavedEntryAndCoverToTargetBottle() async throws {
        let dirA = try fixture()
        let dirB = try fixture()
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }
        let storeA = GameMetadataStore(directory: dirA)
        let storeB = GameMetadataStore(directory: dirB)
        let coverURL = try #require(URL(string: "https://example.invalid/cover.jpg"))
        let metadata = GameMetadata(
            source: .vndb,
            sourceID: "v100",
            title: "Moved Game",
            coverURL: coverURL
        )
        try await storeA.save(metadata, for: "program:drive_c/Games/Moved")
        let coverPath = storeA.coverLocation(for: coverURL)
        try FileManager.default.createDirectory(
            at: coverPath.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("dummy cover".utf8).write(to: coverPath)

        try await storeA.remove(for: "program:drive_c/Games/Unlinked")

        try await storeA.copyEntry(
            for: "program:drive_c/Games/Moved",
            to: storeB,
            targetIdentity: "program:/Games/Moved"
        )
        try await storeA.copyEntry(
            for: "program:drive_c/Games/Unlinked",
            to: storeB,
            targetIdentity: "program:/Games/Unlinked"
        )

        #expect(try await storeB.load(for: "program:/Games/Moved") == metadata)
        #expect(storeB.cachedCoverURL(for: coverURL) != nil)
        #expect(try await storeB.allowsAutomaticMatch(for: "program:/Games/Unlinked") == false)
    }
}
