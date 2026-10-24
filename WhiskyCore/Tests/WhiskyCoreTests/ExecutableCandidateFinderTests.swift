//
//  ExecutableCandidateFinderTests.swift
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

@Suite("Executable candidates in a game folder")
struct ExecutableCandidateFinderTests {
    private func write(_ path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data().write(to: url)
    }

    @Test func nestedExecutablesAreFoundAndScriptsAreNot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try write("top.exe", in: root)
        try write("Data/GameData/launcher.exe", in: root)
        try write("Data/start.bat", in: root)
        try write("Data/install.cmd", in: root)
        try write("Data/setup.msi", in: root)
        try write("Data/Shortcut.lnk", in: root)
        // Case varies across installs, so the extension check cannot be literal.
        try write("Data/GameData/Sub/OTHER.EXE", in: root)

        let found = ExecutableCandidateFinder.candidates(in: root)
        #expect(found.map(\.lastPathComponent) == ["launcher.exe", "OTHER.EXE", "top.exe"])
        let names = Set(found.map { $0.lastPathComponent.lowercased() })
        #expect(!names.contains("start.bat"))
        #expect(!names.contains("install.cmd"))
        #expect(!names.contains("setup.msi"))
        #expect(!names.contains("shortcut.lnk"))
    }

    @Test func aSymlinkedDirectoryIsNeverWalked() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try write("game.exe", in: root)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Nested"), withIntermediateDirectories: true
        )
        try write("Nested/nested.exe", in: root)
        // A link back to the root would otherwise descend forever.
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Nested/loop"), withDestinationURL: root
        )
        let found = ExecutableCandidateFinder.candidates(in: root)
        #expect(found.count == 2)
    }

    @Test func theWalkStopsAtTheDepthAndCountLimits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try write("a.exe", in: root)
        try write("one/b.exe", in: root)
        try write("one/two/c.exe", in: root)
        #expect(ExecutableCandidateFinder.candidates(in: root, maxDepth: 1).count == 1)
        #expect(ExecutableCandidateFinder.candidates(in: root, maxDepth: 2).count == 2)
        #expect(ExecutableCandidateFinder.candidates(in: root, limit: 2).count == 2)
    }

    @Test func hiddenFilesStayOutOfTheList() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try write("game.exe", in: root)
        try write(".cache/tool.exe", in: root)
        #expect(ExecutableCandidateFinder.candidates(in: root).map(\.lastPathComponent) == ["game.exe"])
    }
}
