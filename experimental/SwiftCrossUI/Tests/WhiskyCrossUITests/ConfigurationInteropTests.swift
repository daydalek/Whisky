//
//  ConfigurationInteropTests.swift
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
import WhiskyKit
#endif

@Suite("Configuration production compatibility")
struct ConfigurationInteropTests {
    @Test func realFileLocksPreserveConcurrentEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Metadata.plist")
        let first = ConfigurationFile(url: url, locking: WorkspaceFileLock())
        let second = ConfigurationFile(url: url, locking: WorkspaceFileLock())
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< 30 {
                let store = index.isMultiple(of: 2) ? first : second
                group.addTask { try await store.setEnvironmentVariable("KEY\(index)", value: "\(index)") }
            }
            try await group.waitForAll()
        }
        let values = try await first.strings(at: "environment")
        #expect(values.count == 30)
        for index in 0 ..< 30 {
            #expect(values["KEY\(index)"] == "\(index)")
        }
    }

    #if os(macOS)
    @Test @MainActor func allContainerControlsRoundTripThroughProductionCodec() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("Metadata.plist")
        let output = root.appendingPathComponent("RoundTrip.plist")
        let defaults = try PropertyListEncoder().encode(BottleSettings())
        try defaults.write(to: input)
        let store = ConfigurationFile(url: input, locking: WorkspaceFileLock())
        let initial = try await store.values(for: ContainerConfiguration.fields)
        for field in ContainerConfiguration.fields {
            #expect(initial[field.id] == field.defaultValue, "Default: \(field.id)")
            let candidates: [ConfigurationValue] = switch field.input {
            case .toggle: [.boolean(true), .boolean(false)]
            case .text: [.text("Test"), .text("")]
            case let .number(range): [.integer(range.upperBound), .integer(range.lowerBound)]
            case let .choice(options): options.map { .text($0.id) }
            }
            for value in candidates {
                try await store.update(field, to: value)
                let decoded = try PropertyListDecoder().decode(BottleSettings.self, from: Data(contentsOf: input))
                try PropertyListEncoder().encode(decoded).write(to: output)
                let readBack = try await ConfigurationFile(url: output, locking: WorkspaceFileLock())
                    .values(for: [field])
                #expect(readBack[field.id] == value, "Round trip: \(field.id), \(value)")
            }
        }
    }

    @Test @MainActor func pinsAndProgramEditsAreReadableByNativeServices() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let metadata = root.appendingPathComponent("Metadata.plist")
        try PropertyListEncoder().encode(BottleSettings()).write(to: metadata)
        let executable = root.appendingPathComponent("game.exe")
        try Data().write(to: executable)
        let store = ConfigurationFile(url: metadata, locking: WorkspaceFileLock())
        try await store.setPinned(true, executable: executable, name: "中文游戏")
        try await store.setBlocked(true, executable: executable)
        let native = try PropertyListDecoder().decode(BottleSettings.self, from: Data(contentsOf: metadata))
        #expect(native.pins.first?.url == executable)
        #expect(native.pins.first?.name == "中文游戏")
        #expect(native.blocklist == [executable])
        let locations = ProgramStorageLayout.locations(for: executable, containerURL: root)
        let settings = ConfigurationFile(url: locations.identity, locking: WorkspaceFileLock())
        let locale = ContainerConfiguration.choice("programLocale", "语言", "locale", "", ContainerConfiguration.locales)
        try await settings.update(locale, to: .text("ja_JP.UTF-8"))
        try await settings.update(
            .init("arguments", "参数", path: "arguments", input: .text, defaultValue: .text("")),
            to: .text("--flag '中文'")
        )
        try await settings.setEnvironmentVariable("CUSTOM", value: "literal $HOME")
        let loaded = Program.loadSettings(for: executable, bottleURL: root)
        #expect(loaded.location == locations.identity)
        #expect(loaded.settings.locale == .japanese)
        #expect(loaded.settings.arguments == "--flag '中文'")
        #expect(loaded.settings.environment == [
            "LANG": "ja_JP.UTF-8",
            "LC_ALL": "ja_JP.UTF-8",
            "CUSTOM": "literal $HOME"
        ])
    }

    @Test @MainActor func crossUIHostReadPreservesOfflinePinsAndUnknownMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let metadata = root.appendingPathComponent("Metadata.plist")
        var settings = BottleSettings()
        settings.pins = [PinnedProgram(name: "Offline", url: root.appendingPathComponent("offline.exe"))]
        let data = try PropertyListEncoder().encode(settings)
        var document = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        document["future"] = "retain"
        let original = try PropertyListSerialization.data(fromPropertyList: document, format: .binary, options: 0)
        try original.write(to: metadata)
        let bottle = try #require(WorkspaceHost.bottle(at: root))
        #expect(bottle.settings.pins.count == 1)
        #expect(try Data(contentsOf: metadata) == original)
        settings.name = "External edit"
        try PropertyListEncoder().encode(settings).write(to: metadata)
        WorkspaceHost.refresh([root])
        #expect(WorkspaceHost.bottle(at: root)?.settings.name == "External edit")
        try Data("corrupt".utf8).write(to: metadata)
        WorkspaceHost.refresh([root])
        #expect(WorkspaceHost.bottle(at: root) == nil)
        #expect(try Data(contentsOf: metadata) == Data("corrupt".utf8))
        WorkspaceHost.invalidate(root)
    }
    #endif
}
