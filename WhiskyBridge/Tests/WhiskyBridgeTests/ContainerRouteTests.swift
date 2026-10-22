//
//  ContainerRouteTests.swift
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

private func writeRoutes(_ fixture: LifecycleFixture, alias: URL? = nil) throws -> Data {
    let value: [String: Any] = [
        "10": (alias ?? fixture.source).path + "/",
        "20": [
            "bottle": fixture.source.path,
            "lastLaunched": Date(timeIntervalSince1970: 1_700_000_000),
            "futureRoute": ["retain": true]
        ],
        "30": ["bottle": fixture.root.appendingPathComponent("Other").path, "futureOther": true],
        "opaque": ["bottle": fixture.source.path, "schema": 42]
    ]
    let url = ContainerRoutes.location(fixture.registry)
    try LifecycleFixture.plist(value, at: url)
    return try Data(contentsOf: url)
}

@Test @MainActor func lifecycleMoveRewritesLegacyAndDatedAliasRoutesPreservingOpaqueFields() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let alias = fixture.root.appendingPathComponent("Alias")
    try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: fixture.source.path)
    _ = try writeRoutes(fixture, alias: alias)
    let parent = fixture.root.appendingPathComponent("Moved")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    let result = try await fixture.run("bottle.move", ["destination": .string(parent.path)])
    let target = try #require(result.object?["path"]?.string)
    let routes = try fixture.read(ContainerRoutes.location(fixture.registry))
    #expect(routes["10"] as? String == target)
    let dated = try #require(routes["20"] as? [String: Any])
    #expect(dated["bottle"] as? String == target)
    #expect(dated["lastLaunched"] as? Date == Date(timeIntervalSince1970: 1_700_000_000))
    #expect((dated["futureRoute"] as? [String: Bool])?["retain"] == true)
    #expect((routes["opaque"] as? [String: Any])?["schema"] as? Int == 42)
    #expect((routes["30"] as? [String: Any])?["bottle"] as? String == fixture.root.appendingPathComponent("Other").path)
}

@Test @MainActor func lifecycleCopiesAndDeregistrationRetainRoutesAndPhysicalDeletionPrunesSelectedRoutes(
) async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let original = try writeRoutes(fixture)
    let url = ContainerRoutes.location(fixture.registry)
    _ = try await fixture.run("bottle.duplicate", ["name": .string("Clone")])
    #expect(try Data(contentsOf: url) == original)
    _ = try await fixture.run("bottle.remove")
    #expect(try Data(contentsOf: url) == original)
    var registry = try ContainerRegistry.Document(fixture.workspace)
    try registry.save(registry.paths + [fixture.source])
    _ = try await fixture.run("bottle.remove", ["deleteFiles": .bool(true)])
    let routes = try fixture.read(url)
    #expect(routes["10"] == nil && routes["20"] == nil)
    #expect(routes["30"] != nil && routes["opaque"] != nil)
}

@Test @MainActor func corruptOrBusyRouteStorePreservesSourceAndRegistryBeforeMove() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let url = ContainerRoutes.location(fixture.registry)
    let registry = try Data(contentsOf: fixture.registry)
    let parent = fixture.root.appendingPathComponent("Moved")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    try Data("corrupt routes".utf8).write(to: url)
    await #expect(throws: BridgeFailure.self) {
        try await fixture.run("bottle.move", ["destination": .string(parent.path)])
    }
    #expect(try Data(contentsOf: url) == Data("corrupt routes".utf8))
    #expect(try Data(contentsOf: fixture.registry) == registry)
    _ = try writeRoutes(fixture)
    let lease = try ContainerRegistry.acquire(ApplicationWorkspace(registry: url))
    await #expect(throws: BridgeFailure.self) {
        try await fixture.run("bottle.move", ["destination": .string(parent.path)])
    }
    ContainerRegistry.release(lease)
    #expect(FileManager.default.fileExists(atPath: fixture.executable.path))
    #expect(!ContainerJournal.pending(fixture.registry))
}

@Test @MainActor func committedMoveRouteRecoveryRetriesAfterCorruptionAndRetainsThePrefix() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let alias = fixture.root.appendingPathComponent("Alias")
    try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: fixture.source.path)
    let original = try writeRoutes(fixture, alias: alias)
    let parent = fixture.root.appendingPathComponent("Moved")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    let source = ContainerRegistry.canonical(fixture.source)
    let target = parent.appendingPathComponent("Bottle")
    var registry = try ContainerRegistry.Document(fixture.workspace)
    let journal = try ContainerJournal(
        kind: .move,
        source: source,
        destination: target,
        paths: registry.paths,
        undo: ContainerUndo(source),
        registry: fixture.registry
    )
    try journal.save(fixture.registry)
    #expect(whisky_host_move(source.path, target.path) == 0)
    try ContainerRelocation(source: source, destination: target).apply(at: target)
    try registry.save([target], transaction: journal.id)
    let url = ContainerRoutes.location(fixture.registry)
    try Data("corrupt routes".utf8).write(to: url)
    await #expect(throws: BridgeFailure.self) { try await fixture.run("workspace.recover") }
    #expect(ContainerJournal.pending(fixture.registry))
    #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("Metadata.plist").path))
    try original.write(to: url)
    _ = try await fixture.run("workspace.recover")
    let routes = try fixture.read(url)
    #expect(routes["10"] as? String == target.path)
    #expect((routes["20"] as? [String: Any])?["bottle"] as? String == target.path)
    let done = try Data(contentsOf: url)
    _ = try await fixture.run("workspace.recover")
    #expect(try Data(contentsOf: url) == done)
    #expect(!ContainerJournal.pending(fixture.registry))
}
