//
//  RuntimeCompositionTests.swift
//  WhiskyCrossUITests
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
import WhiskyKit
#endif

@Suite("SwiftCrossUI runtime composition")
struct RuntimeCompositionTests {
    @Test func browsingPreservesConfigurationFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Games/Title"),
            withIntermediateDirectories: true
        )
        var folders = FolderGameLibrary()
        folders.roots = ["Games"]
        try folders.save(bottleURL: root)
        let configuration = root.appendingPathComponent("Folder Games.json")
        let before = try Data(contentsOf: configuration)
        let entries = try readBrowserEntries(root: nil, bottle: root)
        #expect(entries.count == 1)
        #expect(entries.first?.metadataIdentity == "program:Games/Title")
        #expect(try Data(contentsOf: configuration) == before)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Metadata.plist").path))
    }

    @Test func catalogueIncludesPinsSteamAndFoldersWithoutDuplicateSteamGames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let steam = root.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        let steamApps = steam.appendingPathComponent("steamapps")
        try FileManager.default.createDirectory(
            at: steamApps.appendingPathComponent("common/Steam Game"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Games/Local"),
            withIntermediateDirectories: true
        )
        try Data().write(to: steam.appendingPathComponent("steam.exe"))
        try #"""
        "AppState" { "appid" "42" "name" "Steam Game" "installdir" "Steam Game" "StateFlags" "4" }
        """#.write(to: steamApps.appendingPathComponent("appmanifest_42.acf"), atomically: true, encoding: .utf8)
        let metadata = root.appendingPathComponent("Metadata.plist")
        let settings: [String: Any] = ["info": ["name": "Portable", "pins": [
            ["name": "Pin", "url": ["relative": root.appendingPathComponent("pin.exe").absoluteString]]
        ]]]
        try PropertyListSerialization.data(fromPropertyList: settings, format: .binary, options: 0).write(to: metadata)
        let before = try Data(contentsOf: metadata)
        var folders = FolderGameLibrary()
        folders.roots = ["Games", "drive_c/Program Files (x86)/Steam/steamapps/common"]
        try folders.save(bottleURL: root)
        let entries = try readBrowserEntries(root: nil, bottle: root)
        #expect(entries.filter { $0.source == .pinned }.count == 1)
        #expect(entries.filter { $0.source == .steam }.count == 1)
        #expect(entries.filter { $0.source == .folder }.map(\.name) == ["Local"])
        #expect(try Data(contentsOf: metadata) == before)
    }

    #if os(macOS)
    @MainActor @Test func wineRequiresValidatedMetadataAndHonorsBrowsing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let entry = LibraryEntry(
            id: "game",
            name: "Game",
            iconURL: nil,
            bottleURL: root,
            source: .pinned,
            launch: .program(root.appendingPathComponent("game.exe"))
        )
        let metadata = root.appendingPathComponent("Metadata.plist")
        let corrupt = Data("corrupt".utf8)
        try corrupt.write(to: metadata)
        let invalid = makeWorkspaceRuntime(arguments: ["app", "--bottle", root.path])
        #expect(invalid.capabilities(for: entry).isEmpty)
        #expect(try Data(contentsOf: metadata) == corrupt)
        let valid = try PropertyListEncoder().encode(BottleSettings())
        try valid.write(to: metadata)
        let browsing = makeWorkspaceRuntime(arguments: ["app", "--browse-only", "--bottle", root.path])
        #expect(browsing.capabilities(for: entry).isEmpty)
        #expect(try Data(contentsOf: metadata) == valid)
        let connected = makeWorkspaceRuntime(arguments: ["app", "--bottle", root.path])
        #expect(connected.capabilities(for: entry).contains(.launch))
        connected.stopTracking()
    }

    #else
    @MainActor @Test func browsingHostPreservesMetadataWhenWineIsRequested() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let metadata = root.appendingPathComponent("Metadata.plist")
        let existing = Data("existing host metadata".utf8)
        try existing.write(to: metadata)
        let entry = LibraryEntry(
            id: "game", name: "Game", iconURL: nil, bottleURL: root, source: .pinned,
            launch: .program(root.appendingPathComponent("game.exe"))
        )
        let runtime = makeWorkspaceRuntime(arguments: ["app", "--bottle", root.path])
        await runtime.configure(entries: [entry], containerURL: root)
        #expect(runtime.capabilities(for: entry).isEmpty)
        runtime.stopTracking()
        #expect(try Data(contentsOf: metadata) == existing)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["Metadata.plist"])
    }
    #endif
}
