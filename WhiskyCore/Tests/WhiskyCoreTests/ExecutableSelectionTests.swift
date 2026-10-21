//
//  ExecutableSelectionTests.swift
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

@Suite("Portable executable selection")
struct ExecutableSelectionTests {
    private struct Fixture {
        let bottle: URL
        let entry: LibraryEntry
        let executable: URL
    }

    private func fixture() throws -> Fixture {
        let bottle = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = bottle.appendingPathComponent("Games/Title")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let executable = folder.appendingPathComponent("game.EXE")
        try Data().write(to: executable)
        return Fixture(bottle: bottle, entry: LibraryEntry(
            id: "game", name: "Title", iconURL: nil, bottleURL: bottle,
            source: .folder, launch: .program(folder)
        ), executable: executable)
    }

    @MainActor @Test func selectionPersistsAndCachedSelectionSkipsDialog() async throws {
        let fixture = try fixture()
        let (bottle, entry, executable) = (fixture.bottle, fixture.entry, fixture.executable)
        defer { try? FileManager.default.removeItem(at: bottle) }
        var calls = 0
        let picker = ClosureExecutablePicker { _ in
            calls += 1
            return executable
        }
        #expect(try await FolderGameLibrary.resolveExecutable(for: entry, picker: picker) == executable)
        #expect(try await FolderGameLibrary.resolveExecutable(for: entry, picker: picker) == executable)
        #expect(calls == 1)
        #expect(try FolderGameLibrary.load(bottleURL: bottle).executables["Games/Title"] == "Games/Title/game.EXE")
        #expect(try await FolderGameLibrary
            .resolveExecutable(for: entry, chooseAgain: true, picker: picker) == executable)
        #expect(calls == 2)
    }

    @MainActor @Test func suspendedDialogPreservesConcurrentConfigurationChange() async throws {
        let fixture = try fixture()
        let (bottle, entry, executable) = (fixture.bottle, fixture.entry, fixture.executable)
        defer { try? FileManager.default.removeItem(at: bottle) }
        let picker = ClosureExecutablePicker { _ in
            var updated = FolderGameLibrary()
            updated.roots = ["NewGames"]
            updated.excludedFolders = ["Hidden"]
            try? updated.save(bottleURL: bottle)
            await Task.yield()
            return executable
        }
        _ = try await FolderGameLibrary.resolveExecutable(for: entry, picker: picker)
        let saved = try FolderGameLibrary.load(bottleURL: bottle)
        #expect(saved.roots == ["NewGames"])
        #expect(saved.excludedFolders == ["Hidden"])
        #expect(saved.executables["Games/Title"] != nil)
    }

    @MainActor @Test func dialogCancellationKeepsConfigurationUntouched() async throws {
        let fixture = try fixture()
        let (bottle, entry) = (fixture.bottle, fixture.entry)
        defer { try? FileManager.default.removeItem(at: bottle) }
        let picker = ClosureExecutablePicker { _ in nil }
        #expect(try await FolderGameLibrary.resolveExecutable(for: entry, picker: picker) == nil)
        #expect(try FolderGameLibrary.load(bottleURL: bottle).executables.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: bottle.appendingPathComponent("Folder Games.json").path))
    }

    @MainActor @Test func arbitraryFilesFromBackendDialogAreValidated() async throws {
        let fixture = try fixture()
        let (bottle, entry) = (fixture.bottle, fixture.entry)
        defer { try? FileManager.default.removeItem(at: bottle) }
        let textFile = bottle.appendingPathComponent("notes.txt")
        try Data().write(to: textFile)
        let picker = ClosureExecutablePicker { _ in textFile }
        await #expect(throws: ExecutableSelectionError.self) {
            try await FolderGameLibrary.resolveExecutable(for: entry, picker: picker)
        }
        #expect(try FolderGameLibrary.load(bottleURL: bottle).executables.isEmpty)
    }
}
