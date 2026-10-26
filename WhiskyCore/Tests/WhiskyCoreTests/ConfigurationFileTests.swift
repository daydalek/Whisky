//
//  ConfigurationFileTests.swift
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

@Suite("Portable configuration transactions")
struct ConfigurationFileTests {
    final class Lock: ActivityFileLocking, @unchecked Sendable {
        private let lock = NSLock()
        func withExclusiveLock<Result>(at url: URL, operation: () throws -> Result) throws -> Result {
            lock.lock()
            defer { lock.unlock() }
            return try operation()
        }
    }

    @Test func patchesPreserveUnknownFieldsAndTaggedEnums() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Metadata.plist")
        try write([
            "future": ["opaque": Data([1, 2, 3])],
            "wineConfig": ["newOption": 42],
            "launcherConfig": ["backendSwitchedByLauncher": true, "backendMigration": 5]
        ], to: file)
        let store = ConfigurationFile(url: file, locking: Lock())
        let sync = ConfigurationField(
            "sync",
            "同步",
            path: "wineConfig.enhancedSync",
            input: .choice([.init("esync", "ESync")]),
            defaultValue: .text("esync"),
            taggedEnum: true
        )
        // A distinct default also exercises the missing-field write.
        let backend = ConfigurationField(
            "graphicsBackend",
            "图形",
            path: "graphicsConfig.backend",
            input: .choice([.init("dxvk", "DXVK"), .init("recommended", "推荐")]),
            defaultValue: .text("recommended")
        )
        let syncDefault = ConfigurationField(
            "sync",
            "同步",
            path: "wineConfig.enhancedSync",
            input: .choice([.init("msync", "MSync"), .init("esync", "ESync")]),
            defaultValue: .text("msync"),
            taggedEnum: true
        )
        try await store.update(syncDefault, to: .text("esync"))
        try await store.update(backend, to: .text("dxvk"))
        let saved = try document(file)
        #expect((saved["future"] as? [String: Any])?["opaque"] as? Data == Data([1, 2, 3]))
        #expect((saved["wineConfig"] as? [String: Any])?["newOption"] as? Int == 42)
        #expect((saved["launcherConfig"] as? [String: Any])?["backendMigration"] as? Int == 5)
        #expect((saved["launcherConfig"] as? [String: Any])?["backendSwitchedByLauncher"] as? Bool == false)
        #expect(try await store.values(for: [sync])["sync"] == .text("esync"))
    }

    @Test func concurrentActorsRetainDisjointFieldEdits() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Metadata.plist")
        let lock = Lock()
        let first = ConfigurationFile(url: file, locking: lock)
        let second = ConfigurationFile(url: file, locking: lock)
        let fields = (0 ..< 40).map { ConfigurationField(
            "key\($0)",
            "设置",
            path: "config.key\($0)",
            input: .toggle,
            defaultValue: .boolean(false)
        ) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, field) in fields.enumerated() {
                let store = index.isMultiple(of: 2) ? first : second
                group.addTask { try await store.update(field, to: .boolean(true)) }
            }
            try await group.waitForAll()
        }
        let values = try await first.values(for: fields)
        #expect(values.count == 40)
        #expect(values.values.allSatisfy { $0 == .boolean(true) })
    }

    @Test func corruptOrInvalidConfigurationPreservesBytes() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Metadata.plist")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = Data("corrupt data".utf8)
        try original.write(to: file)
        let field = ConfigurationField(
            "size",
            "尺寸",
            path: "display.width",
            input: .number(640 ... 7_680),
            defaultValue: .integer(1_920)
        )
        let store = ConfigurationFile(url: file, locking: Lock())
        await #expect(throws: (any Error).self) { try await store.update(field, to: .integer(2_000)) }
        #expect(try Data(contentsOf: file) == original)
        try write(["display": ["width": 1_920]], to: file)
        let valid = try Data(contentsOf: file)
        await #expect(throws: (any Error).self) { try await store.update(field, to: .integer(-1)) }
        #expect(try Data(contentsOf: file) == valid)
    }

    @Test func gdiUpscalerSchemaAndLegacyMigrationPersistEachChoice() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Metadata.plist")
        try write(["graphicsConfig": ["metalFXSpatial": true, "future": "retained"]], to: file)
        let original = try Data(contentsOf: file)
        let field = try #require(ContainerConfiguration.fields(for: .macOS).first { $0.id == "gdiUpscaler" })
        #expect(!ContainerConfiguration.fields(for: .linux).contains { $0.id == "gdiUpscaler" })
        #expect(field.defaultValue == .text("off"))
        guard case let .choice(options) = field.input else { Issue.record("Expected choice field")
            return
        }
        #expect(options.map(\.id) == ["off", "metalfx", "anime4k", "realcugan", "adaptive"])
        let store = ConfigurationFile(url: file, locking: Lock())
        #expect(try await store.values(for: [field])[field.id] == .text("metalfx"))
        #expect(try Data(contentsOf: file) == original)
        for option in ["off", "anime4k", "realcugan", "adaptive", "metalfx"] {
            try await store.update(field, to: .text(option))
            #expect(try await store.values(for: [field])[field.id] == .text(option))
            let graphics = try #require(try document(file)["graphicsConfig"] as? [String: Any])
            #expect(graphics["metalFXSpatial"] as? Bool == (option == "metalfx"))
            #expect(graphics["future"] as? String == "retained")
        }
        await #expect(throws: (any Error).self) { try await store.update(field, to: .text("unknown")) }
    }

    @Test func legacyDXVKSelectionCanBeReadAndExplicitlyChanged() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Metadata.plist")
        try write(["dxvkConfig": ["dxvk": true], "future": "retain"], to: file)
        let original = try Data(contentsOf: file)
        let field = ConfigurationField(
            "graphicsBackend",
            "图形",
            path: "graphicsConfig.backend",
            input: .choice([.init("recommended", "推荐"), .init("dxvk", "DXVK")]),
            defaultValue: .text("recommended")
        )
        let store = ConfigurationFile(url: file, locking: Lock())
        #expect(try await store.values(for: [field])[field.id] == .text("dxvk"))
        #expect(try Data(contentsOf: file) == original)
        try await store.update(field, to: .text("recommended"))
        #expect(try await store.values(for: [field])[field.id] == .text("recommended"))
        #expect(try document(file)["future"] as? String == "retain")
    }

    @Test func legacyProgramCopyAndLocalePresetsRetainOtherSettings() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("drive_c/Game/game.exe")
        let paths = ProgramStorageLayout.locations(for: executable, containerURL: root)
        try write(
            ["locale": "", "environment": ["CUSTOM": "保留", "LC_ALL": "old"], "arguments": "--old", "future": 9],
            to: paths.legacy
        )
        let legacy = try Data(contentsOf: paths.legacy)
        let store = ConfigurationFile(url: paths.identity, locking: Lock(), fallbackURL: paths.legacy)
        #expect(try await store.strings(at: "environment")["CUSTOM"] == "保留")
        let locale = ConfigurationField(
            "programLocale",
            "语言",
            path: "locale",
            input: .choice([.init("", "自动"), .init("ja_JP.UTF-8", "日本語")]),
            defaultValue: .text("")
        )
        try await store.update(locale, to: .text("ja_JP.UTF-8"))
        #expect(try await store.strings(at: "environment") == [
            "CUSTOM": "保留",
            "LANG": "ja_JP.UTF-8",
            "LC_ALL": "ja_JP.UTF-8"
        ])
        try await store.update(locale, to: .text(""))
        #expect(try await store.strings(at: "environment") == ["CUSTOM": "保留"])
        #expect(try document(paths.identity)["future"] as? Int == 9)
        #expect(try Data(contentsOf: paths.legacy) == legacy)
        #expect(ProgramStorageLayout
            .identity(for: executable, containerURL: root) ==
            "game-\(LibraryStorageLayout.key("/drive_c/Game/game.exe").prefix(8))")
    }

    @Test func pinsBlocklistAndDiscoveryUseOriginalURLCodec() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("drive_c/Program Files/Game")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let game = directory.appendingPathComponent("game.exe")
        for name in ["game.exe", "crashreporter.exe", "data.bin"] {
            try Data().write(to: directory.appendingPathComponent(name))
        }
        let store = ConfigurationFile(url: root.appendingPathComponent("Metadata.plist"), locking: Lock())
        try await store.setPinned(true, executable: game, name: "游戏")
        try await store.setBlocked(true, executable: game)
        let result = try await store.programs(in: root)
        #expect(result.count == 1, "\(result.map(\.url.absoluteString))")
        #expect(result.first?.name == "游戏")
        #expect(result.first?.pinned == true)
        #expect(result.first?.blocked == true)
        try await store.setPinned(false, executable: game, name: "游戏")
        try await store.setBlocked(false, executable: game)
        #expect(try await store.programs(in: root).first?.pinned == false)
        let decoded = try PropertyListDecoder().decode(
            ConfigurationTestMetadata.self,
            from: Data(contentsOf: root.appendingPathComponent("Metadata.plist"))
        )
        #expect(decoded.info.pins.isEmpty)
        #expect(decoded.info.blocklist.isEmpty)
    }

    @Test func symlinkedPinRetainsItsSettingsPathAndSharesHiddenIdentity() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("drive_c/Program Files/Game")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let real = directory.appendingPathComponent("game.exe")
        try Data().write(to: real)
        let aliasDirectory = root.appendingPathComponent("Game Alias")
        try FileManager.default.createSymbolicLink(at: aliasDirectory, withDestinationURL: directory)
        let alias = aliasDirectory.appendingPathComponent("game.exe")
        let store = ConfigurationFile(url: root.appendingPathComponent("Metadata.plist"), locking: Lock())
        try await store.setPinned(true, executable: alias, name: "Alias")
        try await store.setBlocked(true, executable: real)
        let programs = try await store.programs(in: root)
        #expect(programs.count == 1)
        #expect(programs.first?.url == alias)
        #expect(programs.first?.blocked == true)
        try await store.setPinned(false, executable: real, name: "Alias")
        #expect(try await store.programs(in: root).allSatisfy { !$0.pinned })
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0).write(to: url)
    }

    private func document(_ url: URL) throws -> [String: Any] {
        try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
    }
}

private struct ConfigurationTestMetadata: Decodable {
    struct Info: Decodable {
        let pins: [Pin]
        let blocklist: [URL]
    }

    struct Pin: Decodable { let url: URL }
    let info: Info
}
