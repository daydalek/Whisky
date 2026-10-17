//
//  SteamGameProgramTests.swift
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

@Suite("Steam Game Program Selection")
struct SteamGameProgramTests {
    @Test func persistsSelectionAndClearsItWithoutDeletingGame() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let install = root.appendingPathComponent("drive_c/Steam/steamapps/common/Game")
        let exe = install.appendingPathComponent("bin/Game.exe")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: exe)
        #expect(try SteamGameProgram.selectedURL(appID: 1, installURL: install, bottleURL: root) == nil)
        try SteamGameProgram.select(exe, appID: 1, installURL: install, bottleURL: root)
        #expect(try SteamGameProgram.selectedURL(appID: 1, installURL: install, bottleURL: root) == exe)
        #expect(try SteamGameProgram.selectedURL(appID: 2, installURL: install, bottleURL: root) == nil)
        try SteamGameProgram.clear(appID: 1, bottleURL: root)
        #expect(try SteamGameProgram.selectedURL(appID: 1, installURL: install, bottleURL: root) == nil)
        #expect(FileManager.default.fileExists(atPath: exe.path))
    }

    @Test func rejectsEscapingOrNonExecutableTargets() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let install = root.appendingPathComponent("Game")
        for target in [
            root.appendingPathComponent("Other.exe"),
            install.appendingPathComponent("../Other.exe"),
            install.appendingPathComponent("data.txt")
        ] {
            #expect(throws: (any Error).self) {
                try SteamGameProgram.select(target, appID: 1, installURL: install, bottleURL: root)
            }
        }
    }

    @Test func selectionSurvivesBottleMove() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("Original")
        let install = original.appendingPathComponent("Game")
        try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
        let exe = install.appendingPathComponent("Game.exe")
        try Data("MZ".utf8).write(to: exe)
        try SteamGameProgram.select(exe, appID: 1, installURL: install, bottleURL: original)
        let moved = root.appendingPathComponent("Moved")
        try FileManager.default.moveItem(at: original, to: moved)
        #expect(try SteamGameProgram.selectedURL(
            appID: 1, installURL: moved.appendingPathComponent("Game"), bottleURL: moved
        ) == moved.appendingPathComponent("Game/Game.exe"))
    }
}
