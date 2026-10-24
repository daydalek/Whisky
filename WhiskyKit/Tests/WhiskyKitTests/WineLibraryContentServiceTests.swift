//
//  WineLibraryContentServiceTests.swift
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
import WhiskyCore
@testable import WhiskyKit

@Suite("Wine library content adapter")
@MainActor
struct WineLibraryContentServiceTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func entry(_ url: URL, executable: URL, source: LibrarySourceID = .pinned) -> LibraryEntry {
        LibraryEntry(
            id: source.rawValue + ":" + url.path,
            name: "Game",
            iconURL: nil,
            bottleURL: url,
            source: source,
            launch: .program(executable)
        )
    }

    @Test func discoveryWaitsForCommitAndKeepsChangesMadeDuringTheScan() async throws {
        let url = try root()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("Games/New"),
            withIntermediateDirectories: true
        )
        var folders = FolderGameLibrary()
        folders.roots = ["Games"]
        try folders.save(bottleURL: url)
        let configuration = url.appendingPathComponent("Folder Games.json")
        let before = try Data(contentsOf: configuration)
        let service: any LibraryContentProviding = WineLibraryContentService()
        let result = try await service.discover(in: url)
        #expect(result.entries.map(\.name) == ["New"])
        #expect(try Data(contentsOf: configuration) == before)
        folders.executables = ["Games/New": "Games/New/chosen.exe"]
        try folders.save(bottleURL: url)
        try service.commit(result)
        let saved = try FolderGameLibrary.load(bottleURL: url)
        #expect(saved.knownFolders == ["Games/New"])
        #expect(saved.executables == folders.executables)
        folders.roots = ["Other"]
        folders.knownFolders = ["Other/Current"]
        try folders.save(bottleURL: url)
        let changed = try Data(contentsOf: configuration)
        try service.commit(result)
        #expect(try Data(contentsOf: configuration) == changed)
    }

    @Test func activityAndVisibilityUseTheInjectedRecordStore() async throws {
        let url = try root()
        defer { try? FileManager.default.removeItem(at: url) }
        let game = entry(url, executable: url.appendingPathComponent("game.exe"))
        let store = GameActivityStore()
        try store.record(30, at: Date(timeIntervalSince1970: 100), for: game)
        try store.setRating(9, for: game)
        let service: any LibraryContentProviding = WineLibraryContentService(store: store)
        #expect(try service.activity(for: game) == store.load(for: game))
        #expect(try await service.activities(for: [game])[game.id]?.playTime == 30)
        #expect(try service.setHidden(true, for: game).hiddenIdentities == [game.metadataIdentity])
        #expect(try service.visibility(in: url).hiddenIdentities == [game.metadataIdentity])
        #expect(try service.setHidden(false, for: game).hiddenIdentities.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(
            at: url.appendingPathComponent("Game Activity"), includingPropertiesForKeys: nil
        )
        let record = try #require(files.first { $0.pathExtension == "json" })
        try Data("corrupt".utf8).write(to: record)
        #expect(throws: (any Error).self) { try service.activity(for: game) }
        #expect(try await service.activities(for: [game]).isEmpty)
    }

    @Test func pinnedMovePreservesProgramSettingsMetadataHistoryAndVisibility() async throws {
        let url = try root()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = Bottle(bottleUrl: url.appendingPathComponent("source"))
        let target = Bottle(bottleUrl: url.appendingPathComponent("target"))
        try FileManager.default.createDirectory(at: source.url, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target.url, withIntermediateDirectories: true)
        let executable = source.url.appendingPathComponent("game.exe")
        try Data().write(to: executable)
        let program = Program(url: executable, bottle: source)
        program.settings.arguments = "--saved-content-setting"
        program.pinned = true
        source.programs = [program]
        source.settings.pins = [PinnedProgram(name: "Game", url: executable)]
        SettingsPersistence.shared.flush()
        let game = entry(source.url, executable: executable)
        let metadata = GameMetadata(source: .vndb, sourceID: "1", title: "Saved title")
        try await GameMetadataStore(directory: game.metadataDirectory).save(metadata, for: game.metadataIdentity)
        let records = GameActivityStore()
        try records.setRating(8, for: game)
        try records.record(90, at: Date(timeIntervalSince1970: 100), for: game)
        let service: any LibraryContentProviding = WineLibraryContentService(bottleResolver: {
            $0 == source.url ? source : ($0 == target.url ? target : nil)
        }, store: records)
        _ = try service.setHidden(true, for: game)
        let moved = try await service.move(game, to: target.url, hidden: true)
        #expect(source.settings.pins.isEmpty && program.pinned == false)
        #expect(target.settings.pins.map(\.url) == [executable])
        #expect(target.programs.first?.settings.arguments == "--saved-content-setting")
        #expect(try records.load(for: moved).rating == 8)
        #expect(try records.load(for: moved).playTime == 90)
        #expect(try service.visibility(in: target.url).hiddenIdentities == [moved.metadataIdentity])
        #expect(try await GameMetadataStore(directory: moved.metadataDirectory)
            .load(for: moved.metadataIdentity) == metadata)
    }

    @Test func folderMovePreservesExecutableMappingAndTargetLease() async throws {
        let url = try root()
        defer { try? FileManager.default.removeItem(at: url) }
        let sourceURL = url.appendingPathComponent("source")
        let target = Bottle(bottleUrl: url.appendingPathComponent("target"))
        let folder = sourceURL.appendingPathComponent("Games/Title")
        let executable = folder.appendingPathComponent("game.exe")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target.url, withIntermediateDirectories: true)
        try Data().write(to: executable)
        var source = FolderGameLibrary()
        source.roots = ["Games"]
        source.executables["Games/Title"] = "Games/Title/game.exe"
        source.knownFolders = ["Games/Title"]
        try source.save(bottleURL: sourceURL)
        let game = entry(sourceURL, executable: folder, source: .folder)
        let expected = LibraryEntry(
            id: game.id,
            name: game.name,
            iconURL: nil,
            bottleURL: target.url,
            source: .folder,
            launch: game.launch
        )
        let records = GameActivityStore()
        try records.record(120, at: Date(), for: game)
        let owner = try records.acquireOwnership(for: expected, source: .worker)
        let service: any LibraryContentProviding = WineLibraryContentService(bottleResolver: {
            $0 == target.url ? target : nil
        }, store: records)
        let moved = try await service.move(game, to: target.url, hidden: false)
        let current = try FolderGameLibrary.load(bottleURL: target.url)
        #expect(current.executable(for: folder, bottleURL: target.url) == executable)
        #expect(try FolderGameLibrary.load(bottleURL: sourceURL).excludedFolders == ["Games/Title"])
        #expect(try records.load(for: moved).owner == owner)
        #expect(try records.load(for: moved).playTime == 120)
        #expect(try service.visibility(in: target.url).hiddenIdentities.isEmpty)
    }
}
