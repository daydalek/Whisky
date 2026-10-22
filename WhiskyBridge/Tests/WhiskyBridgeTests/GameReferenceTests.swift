//
//  GameReferenceTests.swift
//  WhiskyBridgeTests
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
import WhiskyApplication
import WhiskyBridgeProtocol
import WhiskyCore

private struct GameReferenceFixture {
    let root: URL
    let container: URL
    let executable: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("game-reference-\(UUID())")
        container = root.appendingPathComponent("Bottle")
        executable = container.appendingPathComponent("drive_c/AoE2DE/AoE2DE_s.exe")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x4D, 0x5A]).write(to: executable)
        struct Pin: Encodable { let name: String
            let url: URL
            let removable: Bool
        }
        struct Info: Encodable { let name: String
            let pins: [Pin]
            let blocklist: [URL]
        }
        struct Metadata: Encodable { let info: Info }
        let value = Metadata(info: Info(
            name: "Reference",
            pins: [Pin(name: "AoE2", url: executable, removable: false)],
            blocklist: []
        ))
        try PropertyListEncoder().encode(value).write(to: container.appendingPathComponent("Metadata.plist"))
        try Data("keep opaque settings".utf8).write(to: container.appendingPathComponent("BottleSettings.plist"))
    }

    var workspace: ApplicationWorkspace {
        ApplicationWorkspace(registry: root.appendingPathComponent("BottleVM.plist"), containers: [container])
    }

    var params: [String: JSONValue] {
        ["container": .string(container.path), "entryID": .string("pinned:" + executable.path)]
    }

    func snapshot() throws -> [String: Data] {
        let enumerator = try #require(FileManager.default.enumerator(
            at: container,
            includingPropertiesForKeys: [.isRegularFileKey]
        ))
        var result: [String: Data] = [:]
        for case let url as URL in enumerator
            where try (url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            result[url.path] = try Data(contentsOf: url)
        }
        return result
    }
}

@Test @MainActor func portableGameReferenceMatchesAndPreservesAllContainerBytes() async throws {
    let fixture = try GameReferenceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let before = try fixture.snapshot()
    let service = ApplicationService(workspace: fixture.workspace)
    let described = try await service.call("bridge.describe", params: [:])
    #expect(described.object?["methods"]?.array?.contains(.string("gameConfig.match")) == true)
    #expect(described.object?["methods"]?.array?.contains(.string("gameConfig.apply")) == false)
    let response = try await service.call("gameConfig.match", params: fixture.params)
    let matched = try #require(response.object?["matches"]?.array?.first?.object)
    #expect(matched["entry"]?.object?["id"] == .string("aoe2-de"))
    #expect(matched["canApply"] == .bool(false) && matched["referencePlatform"] == .string("macos"))
    #expect(matched["availabilityReason"]?.string?.contains("macOS 14.0.0+") == true)
    #expect(matched["changes"]?.array?.isEmpty == false)
    do {
        _ = try await service.call("gameConfig.apply", params: fixture.params)
        Issue.record("A file-only session accepted runtime configuration application")
    } catch let error as BridgeFailure { #expect(error.code == "method_unavailable") }
    let journal = fixture.workspace.registry.appendingPathExtension("lifecycle.plist")
    let retainedJournal = Data("retained interrupted operation".utf8)
    try retainedJournal.write(to: journal)
    do {
        _ = try await service.call("gameConfig.match", params: fixture.params)
        Issue.record("GameDB read entered a container with pending recovery")
    } catch let error as BridgeFailure { #expect(error.code == "recovery_pending") }
    #expect(try Data(contentsOf: journal) == retainedJournal)
    #expect(try fixture.snapshot() == before)
    await service.shutdown()
}

@Test @MainActor func invalidDatabaseAndUnregisteredEntryKeepReferenceFilesIntact() async throws {
    let fixture = try GameReferenceFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let before = try fixture.snapshot()
    let corrupt = GameReferenceService(load: { Data(#"{"version":3,"entries":[]}"#.utf8) })
    await #expect(throws: (any Error).self) { try await corrupt.match(
        params: fixture.params,
        workspace: fixture.workspace
    ) }
    var invalid = fixture.params
    invalid["container"] = .string(fixture.root.appendingPathComponent("other").path)
    await #expect(throws: (any Error).self) { try await GameReferenceService().match(
        params: invalid,
        workspace: fixture.workspace
    ) }
    #expect(try fixture.snapshot() == before)
}
