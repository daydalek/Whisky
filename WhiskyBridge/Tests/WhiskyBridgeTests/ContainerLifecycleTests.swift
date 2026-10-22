//
//  ContainerLifecycleTests.swift
//  WhiskyBridge
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

import CHostCommand
import Foundation
import Testing
@testable import WhiskyApplication
import WhiskyBridgeProtocol

struct LifecycleFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("lifecycle-" + UUID().uuidString)
        .resolvingSymlinksInPath()
    var source: URL {
        root.appendingPathComponent("Bottle")
    }

    var registry: URL {
        root.appendingPathComponent("BottleVM.plist")
    }

    var workspace: ApplicationWorkspace {
        ApplicationWorkspace(registry: registry)
    }

    var params: [String: JSONValue] {
        ["container": .string(source.path)]
    }

    var executable: URL {
        source.appendingPathComponent("drive_c/Game/game.exe")
    }

    init() throws {
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture game".utf8).write(to: executable)
        let metadata: [String: Any] = ["info": ["name": "Original", "pins": [
            ["name": "Game", "url": ["relative": executable.absoluteString], "futurePin": 42]
        ], "blocklist": [["relative": executable.absoluteString]]], "opaque": ["retain": true]]
        try Self.plist(metadata, at: source.appendingPathComponent("Metadata.plist"))
        try Self.plist(
            ["paths": [["relative": source.absoluteString]], "futureRegistry": ["retain": true]],
            at: registry
        )
    }

    static func plist(_ value: Any, at url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0).write(to: url)
    }

    func read(_ url: URL) throws -> [String: Any] {
        try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor func service() -> ApplicationService {
        ApplicationService(workspace: workspace)
    }

    @MainActor func run(
        _ method: String, _ extra: [String: JSONValue] = [:], service: ApplicationService? = nil
    ) async throws -> JSONValue {
        let service = service ?? self.service()
        let started = try await service.call(method, params: params.merging(extra) { _, value in value })
        guard let id = started.object?["jobID"]?.string else { return started }
        for _ in 0 ..< 2_000 {
            let state = try await service.call("jobs.get", params: ["jobID": .string(id)])
            switch state.object?["status"]?.string {
            case "completed": return state.object?["result"] ?? .null
            case "failed", "cancelled":
                throw BridgeFailure(
                    state.object?["error"]?.object?["code"]?.string ?? "test_failed",
                    state.object?["error"]?.object?["message"]?.string ?? "Lifecycle job failed"
                )
            default: try await Task.sleep(for: .milliseconds(5))
            }
        }
        throw BridgeFailure("test_timeout", "Lifecycle job did not complete")
    }
}

@Test @MainActor func portableLifecycleRenamePreservesOpaqueFieldsAndRegistry() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let before = try Data(contentsOf: fixture.registry)
    _ = try await fixture.run("bottle.rename", ["name": .string("  新名字  ")])
    let document = try fixture.read(fixture.source.appendingPathComponent("Metadata.plist"))
    #expect((document["info"] as? [String: Any])?["name"] as? String == "新名字")
    #expect((document["opaque"] as? [String: Bool])?["retain"] == true)
    #expect(try Data(contentsOf: fixture.registry) == before)
    await #expect(throws: BridgeFailure.self) { try await fixture.run("bottle.rename", ["name": .string("  ")]) }
}

@Test @MainActor func portableLifecycleDuplicateRelocatesInternalPathsAndPreservesExternalLinks() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let outside = fixture.root.appendingPathComponent("outside.txt")
    try Data("external data".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(
        atPath: fixture.source.appendingPathComponent("internal").path,
        withDestinationPath: fixture.executable.path
    )
    try FileManager.default.createSymbolicLink(
        atPath: fixture.source.appendingPathComponent("external").path,
        withDestinationPath: outside.path
    )
    let folderDocument: [String: Any] = [
        "roots": [fixture.source.appendingPathComponent("drive_c").path],
        "executables": ["drive_c/Game": "drive_c/Game/game.exe"],
        "futureFolder": ["retain": true]
    ]
    try JSONSerialization.data(withJSONObject: folderDocument)
        .write(to: fixture.source.appendingPathComponent("Folder Games.json"))
    let original = try Data(contentsOf: fixture.source.appendingPathComponent("Metadata.plist"))
    let result = try await fixture.run("bottle.duplicate", ["name": .string("Clone")])
    let target = try URL(fileURLWithPath: #require(result.object?["path"]?.string))
    let metadata = try fixture.read(target.appendingPathComponent("Metadata.plist"))
    let info = try #require(metadata["info"] as? [String: Any])
    #expect(info["name"] as? String == "Clone")
    let pins = try #require(info["pins"] as? [[String: Any]])
    #expect((pins.first?["url"] as? [String: String])?["relative"] == target
        .appendingPathComponent("drive_c/Game/game.exe").absoluteString)
    #expect(pins.first?["futurePin"] as? Int == 42)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.appendingPathComponent("internal").path)
        == target.appendingPathComponent("drive_c/Game/game.exe").path)
    #expect(try FileManager.default
        .destinationOfSymbolicLink(atPath: target.appendingPathComponent("external").path) == outside.path)
    #expect(try Data(contentsOf: fixture.source.appendingPathComponent("Metadata.plist")) == original)
    #expect(try String(contentsOf: outside, encoding: .utf8) == "external data")
    let folders = try #require(JSONSerialization
        .jsonObject(with: Data(contentsOf: target.appendingPathComponent("Folder Games.json"))) as? [String: Any])
    #expect(folders["roots"] as? [String] == [target.appendingPathComponent("drive_c").path])
    #expect((folders["futureFolder"] as? [String: Bool])?["retain"] == true)
    #expect(try fixture.workspace.containers().count == 2)
    #expect(try (fixture.read(fixture.registry)["futureRegistry"] as? [String: Bool])?["retain"] == true)
}

@Test @MainActor func portableLifecycleMovePersistsRelocatedPinsAndRollsBackCorruptFolders() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let parent = fixture.root.appendingPathComponent("Destination")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    let marker = fixture.source.appendingPathComponent("Metadata.plist")
    let original = try Data(contentsOf: marker)
    let folder = fixture.source.appendingPathComponent("Folder Games.json")
    try Data("corrupt JSON".utf8).write(to: folder)
    await #expect(throws: BridgeFailure.self) {
        try await fixture.run("bottle.move", ["destination": .string(parent.path)])
    }
    #expect(try Data(contentsOf: marker) == original)
    #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("Bottle").path))
    try FileManager.default.removeItem(at: folder)
    let moved = try await fixture.run("bottle.move", ["destination": .string(parent.path)])
    let target = try URL(fileURLWithPath: #require(moved.object?["path"]?.string))
    #expect(!FileManager.default.fileExists(atPath: fixture.source.path))
    #expect(try fixture.workspace.containers().first?.path == target.path)
    let entries = try await fixture.workspace.entries(in: target)
    #expect(entries.first?.id == "pinned:" + target.appendingPathComponent("drive_c/Game/game.exe").path)
}

@Test @MainActor func portableLifecycleRemovalKeepsFilesOrDeletesOnlyItsOwnTree() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let data = try Data(contentsOf: fixture.source.appendingPathComponent("Metadata.plist"))
    _ = try await fixture.run("bottle.remove")
    #expect(try fixture.workspace.containers().isEmpty)
    #expect(try Data(contentsOf: fixture.source.appendingPathComponent("Metadata.plist")) == data)
    try LifecycleFixture.plist(["paths": [["relative": fixture.source.absoluteString]]], at: fixture.registry)
    let outside = fixture.root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    try Data("external data".utf8).write(to: outside.appendingPathComponent("data"))
    try FileManager.default.createSymbolicLink(
        atPath: fixture.source.appendingPathComponent("external").path,
        withDestinationPath: outside.path
    )
    _ = try await fixture.run("bottle.remove", ["deleteFiles": .bool(true)])
    #expect(try fixture.workspace.containers().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.source.path))
    #expect(try String(contentsOf: outside.appendingPathComponent("data"), encoding: .utf8) == "external data")
}

@Test @MainActor func portableLifecycleExportsRelativeArchiveAndPreservesExistingDestinations() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let destination = fixture.root.appendingPathComponent("导出 $HOME.tar")
    _ = try await fixture.run("bottle.export", ["destination": .string(destination.path)])
    let result = try await HostCommand.run(
        executable: URL(fileURLWithPath: "/usr/bin/tar"),
        arguments: ["-tzf", destination.path],
        environment: ProcessInfo.processInfo.environment,
        timeout: 10
    )
    let output = try #require(String(bytes: result.output, encoding: .utf8))
    #expect(result.status == 0 && output.contains("Bottle/drive_c/Game/game.exe"))
    #expect(output.split(separator: "\n").allSatisfy { $0.hasPrefix("Bottle/") })
    let original = try Data(contentsOf: destination)
    await #expect(throws: BridgeFailure.self) {
        try await fixture.run("bottle.export", ["destination": .string(destination.path)])
    }
    #expect(try Data(contentsOf: destination) == original)
}

@Test @MainActor func portableLifecycleHonorsRegistryLeaseAndForeignContainerBoundary() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let descriptor = try ContainerRegistry.acquire(fixture.workspace)
    let before = try Data(contentsOf: fixture.registry)
    await #expect(throws: BridgeFailure.self) { try await fixture.run("bottle.rename", ["name": .string("Busy")]) }
    ContainerRegistry.release(descriptor)
    let service = fixture.service()
    await #expect(throws: BridgeFailure.self) {
        try await service.call(
            "bottle.rename",
            params: ["container": .string(fixture.root.path), "name": .string("Foreign")]
        )
    }
    #expect(try Data(contentsOf: fixture.registry) == before)
}

@Test func portableLifecycleAtomicMovePreservesExistingDestination() throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let destination = fixture.root.appendingPathComponent("Existing")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let marker = destination.appendingPathComponent("keep")
    try Data("existing destination".utf8).write(to: marker)
    #expect(whisky_host_move(fixture.source.path, destination.path) != 0)
    #expect(try Data(contentsOf: fixture.executable) == Data("fixture game".utf8))
    #expect(try String(contentsOf: marker, encoding: .utf8) == "existing destination")
}

@Test @MainActor func portableLifecycleMoveUpdatesAliasesResolvedBeforeTheDirectoryMoves() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let alias = fixture.root.appendingPathComponent("Alias")
    try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: fixture.source.path)
    try LifecycleFixture.plist(["paths": [
        ["relative": fixture.source.absoluteString],
        ["relative": alias.absoluteString]
    ]], at: fixture.registry)
    let parent = fixture.root.appendingPathComponent("Moved")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    _ = try await fixture.run("bottle.move", ["destination": .string(parent.path)])
    let containers = try fixture.workspace.containers()
    #expect(containers.count == 1)
    #expect(containers.first?.path == parent.appendingPathComponent("Bottle").path)
}
