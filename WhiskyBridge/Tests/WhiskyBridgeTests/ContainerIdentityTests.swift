//
//  ContainerIdentityTests.swift
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

import Foundation
import Testing
@testable import WhiskyApplication
import WhiskyBridgeProtocol

private func allocateIdentity(_ fixture: LifecycleFixture) throws -> String {
    var registry = try ContainerRegistry.Document(fixture.workspace)
    return try registry.containerIdentity(fixture.source)
}

@Test @MainActor func containerIdentitySurvivesMoveAndKeepsCloneIndependent() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let id = try allocateIdentity(fixture)
    let parent = fixture.root.appendingPathComponent("Moved")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    _ = try await fixture.run("bottle.move", ["destination": .string(parent.path)])
    let moved = parent.appendingPathComponent("Bottle")
    var registry = try ContainerRegistry.Document(fixture.workspace)
    #expect(try registry.resolveIdentity(id) == moved)
    #expect(try registry.containerIdentity(moved) == id)
    let service = fixture.service()
    let cloned = try await fixture.run(
        "bottle.duplicate",
        ["container": .string(moved.path), "name": .string("Clone")],
        service: service
    )
    let clone = try URL(fileURLWithPath: #require(cloned.object?["path"]?.string))
    registry = try ContainerRegistry.Document(fixture.workspace)
    #expect(try registry.containerIdentity(clone) != id)
    #expect(try registry.resolveIdentity(id) == moved)
}

@Test @MainActor func deregistrationRetainsIdentityAndPhysicalDeletionPrunesIt() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let id = try allocateIdentity(fixture)
    _ = try await fixture.run("bottle.remove", ["deleteFiles": .bool(false)])
    #expect(throws: (any Error).self) { try ContainerRegistry.Document(fixture.workspace).resolveIdentity(id) }
    _ = try await fixture.service().call("workspace.import", params: ["path": .string(fixture.source.path)])
    #expect(try ContainerRegistry.Document(fixture.workspace).resolveIdentity(id) == fixture.source)
    _ = try await fixture.run("bottle.remove", ["deleteFiles": .bool(true)])
    #expect(throws: (any Error).self) { try ContainerRegistry.Document(fixture.workspace).resolveIdentity(id) }
    #expect(try (fixture.read(fixture.registry)[ContainerIdentities.key] as? [String: Any])?.isEmpty == true)
}

@Test func directoryReplacementDoesNotRebindAnOldShortcut() throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let id = try allocateIdentity(fixture)
    let retained = fixture.root.appendingPathComponent("Retained")
    try FileManager.default.moveItem(at: fixture.source, to: retained)
    try FileManager.default.copyItem(at: retained, to: fixture.source)
    var registry = try ContainerRegistry.Document(fixture.workspace)
    #expect(throws: (any Error).self) { try registry.resolveIdentity(id) }
    let replacement = try registry.containerIdentity(fixture.source)
    #expect(replacement != id)
    #expect(throws: (any Error).self) { try registry.resolveIdentity(id) }
}

@Test(arguments: [false, true]) func moveRecoveryKeepsIdentityAtTheRegistryCommitBoundary(committed: Bool) throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let id = try allocateIdentity(fixture)
    let parent = fixture.root.appendingPathComponent("Recovered")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    let destination = parent.appendingPathComponent("Bottle")
    var registry = try ContainerRegistry.Document(fixture.workspace)
    let journal = try ContainerJournal(
        kind: .move,
        source: fixture.source,
        destination: destination,
        paths: registry.paths,
        undo: ContainerUndo(fixture.source),
        registry: fixture.registry
    )
    try journal.save(fixture.registry)
    try FileManager.default.moveItem(at: fixture.source, to: destination)
    try ContainerRelocation(source: fixture.source, destination: destination).apply(at: destination)
    if committed {
        try registry.save([destination], transaction: journal.id, relocating: journal.sourceIdentity, to: destination)
    }
    _ = try ContainerRecovery.run(fixture.workspace)
    #expect(try ContainerRegistry.Document(fixture.workspace)
        .resolveIdentity(id).path == (committed ? destination : fixture.source).path)
}

@Test @MainActor func corruptIdentityRecordsBlockMoveBeforeTreeMutation() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    var values = try fixture.read(fixture.registry)
    values[ContainerIdentities.key] = ["broken": ["path": fixture.source.path]]
    try LifecycleFixture.plist(values, at: fixture.registry)
    let before = try Data(contentsOf: fixture.registry)
    let parent = fixture.root.appendingPathComponent("Destination")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    await #expect(throws: (any Error).self) {
        try await fixture.run("bottle.move", ["destination": .string(parent.path)])
    }
    #expect(FileManager.default.fileExists(atPath: fixture.source.path))
    #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("Bottle").path))
    #expect(try Data(contentsOf: fixture.registry) == before)
}

@Test @MainActor func stableShortcutResolutionRejectsTraversalAndReturnsTheCurrentProgram() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let id = try allocateIdentity(fixture)
    let service = LinuxDesktopService(environment: [:], searchPaths: [])
    let result = try await service.call(
        "system.desktop.resolve",
        params: [
            "containerID": .string(id),
            "path": .string("drive_c/Game/game.exe")
        ],
        workspace: fixture.workspace
    )
    #expect(result.object?["path"] == .string(fixture.executable.path))
    await #expect(throws: (any Error).self) {
        try await service.call(
            "system.desktop.resolve",
            params: [
                "containerID": .string(id),
                "path": .string("../foreign.exe")
            ],
            workspace: fixture.workspace
        )
    }
}

@Test @MainActor func shortcutThroughAPrefixAliasUsesTheStableRelativeProgram() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let alias = fixture.root.appendingPathComponent("Alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.source)
    let launcher = fixture.root.appendingPathComponent("frontend")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: launcher)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
    let desktop = LinuxDesktopService(environment: [:], searchPaths: [])
    let result = try await desktop.call("programs.shortcut.create", params: fixture.params.merging([
        "launcher": .string(launcher.path),
        "executable": .string(alias.appendingPathComponent("drive_c/Game/game.exe").path),
        "destination": .string(fixture.root.path)
    ]) { _, value in value }, workspace: fixture.workspace)
    #expect(result.object?["programPath"] == .string("drive_c/Game/game.exe"))
}
