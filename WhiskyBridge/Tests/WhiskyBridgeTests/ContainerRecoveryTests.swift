//
//  ContainerRecoveryTests.swift
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

@Test @MainActor func lifecycleRecoveryRollsBackMovedDocumentsAndAnInterruptedLinkRewrite() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let marker = fixture.source.appendingPathComponent("Metadata.plist")
    let original = try Data(contentsOf: marker)
    let link = fixture.source.appendingPathComponent("internal")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: fixture.executable.path)
    let parent = fixture.root.appendingPathComponent("Moved")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    let destination = parent.appendingPathComponent("Bottle")
    let record = try ContainerJournal(
        kind: .move,
        source: fixture.source,
        destination: destination,
        paths: ContainerRegistry.Document(fixture.workspace).paths,
        undo: ContainerUndo(fixture.source)
    )
    try record.save(fixture.registry)
    #expect(whisky_host_move(fixture.source.path, destination.path) == 0)
    let relocation = ContainerRelocation(source: fixture.source, destination: destination)
    try relocation.apply(at: destination)
    try FileManager.default.removeItem(at: destination.appendingPathComponent("internal"))
    let result = try await fixture.run("workspace.recover")
    #expect(result.object?["outcome"] == .string("rolled_back"))
    #expect(try Data(contentsOf: marker) == original)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == fixture.executable.path)
    #expect(!ContainerJournal.pending(fixture.registry))
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test @MainActor func lifecycleRecoveryRollsBackOnlyItsOwnedUncommittedCopy() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let before = try Data(contentsOf: fixture.registry)
    let destination = fixture.root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    try Data("partial copy".utf8).write(to: destination.appendingPathComponent("partial"))
    let record = try ContainerJournal(
        kind: .duplicate,
        source: fixture.source,
        destination: destination,
        paths: ContainerRegistry.Document(fixture.workspace).paths
    )
    try record.save(fixture.registry)
    _ = try await fixture.run("workspace.recover")
    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(try Data(contentsOf: fixture.registry) == before)
    #expect(try String(contentsOf: fixture.executable, encoding: .utf8) == "fixture game")
}

@Test @MainActor func lifecycleRecoveryRetainsCommittedCloneAndFinishesCrossMoveCleanup() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let clone = fixture.root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.copyItem(at: fixture.source, to: clone)
    let duplicate = try ContainerJournal(
        kind: .duplicate,
        source: fixture.source,
        destination: clone,
        paths: ContainerRegistry.Document(fixture.workspace).paths
    )
    try duplicate.save(fixture.registry)
    var registry = try ContainerRegistry.Document(fixture.workspace)
    try registry.save(registry.paths + [clone], transaction: duplicate.id)
    let duplicated = try await fixture.run("workspace.recover")
    #expect(duplicated.object?["outcome"] == .string("committed"))
    #expect(FileManager.default.fileExists(atPath: clone.path))

    let parent = fixture.root.appendingPathComponent("Other device fixture")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    let moved = parent.appendingPathComponent("Bottle")
    try FileManager.default.copyItem(at: fixture.source, to: moved)
    let cross = try ContainerJournal(
        kind: .crossMove,
        source: fixture.source,
        destination: moved,
        paths: ContainerRegistry.Document(fixture.workspace).paths
    )
    try cross.save(fixture.registry)
    registry = try ContainerRegistry.Document(fixture.workspace)
    try registry.save([clone, moved], transaction: cross.id)
    _ = try await fixture.run("workspace.recover")
    #expect(!FileManager.default.fileExists(atPath: fixture.source.path))
    #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("Metadata.plist").path))
    #expect(!ContainerJournal.pending(fixture.registry))
}

@Test @MainActor func lifecycleRecoveryUsesRegistryCommitForStagedRemoval() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let staging = fixture.root.appendingPathComponent(".whisky-removing-" + UUID().uuidString)
    let record = try ContainerJournal(
        kind: .remove,
        source: fixture.source,
        destination: staging,
        paths: ContainerRegistry.Document(fixture.workspace).paths
    )
    try record.save(fixture.registry)
    #expect(whisky_host_move(fixture.source.path, staging.path) == 0)
    _ = try await fixture.run("workspace.recover")
    #expect(FileManager.default.fileExists(atPath: fixture.executable.path))
    let committed = try ContainerJournal(
        kind: .remove,
        source: fixture.source,
        destination: staging,
        paths: ContainerRegistry.Document(fixture.workspace).paths
    )
    try committed.save(fixture.registry)
    #expect(whisky_host_move(fixture.source.path, staging.path) == 0)
    var registry = try ContainerRegistry.Document(fixture.workspace)
    try registry.save([], transaction: committed.id)
    _ = try await fixture.run("workspace.recover")
    #expect(!FileManager.default.fileExists(atPath: staging.path))
    #expect(try fixture.workspace.containers().isEmpty)
}

@Test @MainActor func lifecycleRecoveryPreservesReplacedDirectoriesAndItsJournalForInspection() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let destination = fixture.root.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let record = try ContainerJournal(
        kind: .duplicate,
        source: fixture.source,
        destination: destination,
        paths: ContainerRegistry.Document(fixture.workspace).paths
    )
    try record.save(fixture.registry)
    let rescue = fixture.root.appendingPathComponent("Retained original")
    try FileManager.default.moveItem(at: destination, to: rescue)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let marker = destination.appendingPathComponent("foreign")
    try Data("foreign data".utf8).write(to: marker)
    await #expect(throws: BridgeFailure.self) { try await fixture.run("workspace.recover") }
    #expect(try String(contentsOf: marker, encoding: .utf8) == "foreign data")
    #expect(ContainerJournal.pending(fixture.registry))
    #expect(FileManager.default.fileExists(atPath: rescue.path))
}

@Test @MainActor func lifecycleRecoveryPreservesCorruptJournalAndBlocksNewWrites() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let before = try Data(contentsOf: fixture.source.appendingPathComponent("Metadata.plist"))
    let journal = ContainerJournal.location(fixture.registry)
    try Data("corrupt recovery record".utf8).write(to: journal)
    await #expect(throws: BridgeFailure.self) { try await fixture.run("bottle.rename", ["name": .string("Blocked")]) }
    await #expect(throws: BridgeFailure.self) { try await fixture.run("workspace.recover") }
    #expect(try Data(contentsOf: journal) == Data("corrupt recovery record".utf8))
    #expect(try Data(contentsOf: fixture.source.appendingPathComponent("Metadata.plist")) == before)
}

@Test @MainActor func lifecycleLeaseBlocksOrdinaryWritesBeforeJournalPublication() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let lease = try ContainerRegistry.acquire(fixture.workspace)
    await #expect(throws: BridgeFailure.self) {
        try await fixture.service().call("environment.set", params: fixture.params.merging([
            "key": .string("TEST"), "value": .string("blocked")
        ]) { _, value in value })
    }
    ContainerRegistry.release(lease)
    let result = try await fixture.service().call("environment.read", params: fixture.params)
    #expect(result == .object([:]))
}

@Test @MainActor func ordinaryJobsHoldSharedWorkspaceLeaseThroughCancellationUnwind() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let jobs = BridgeJobStore()
    let service = ApplicationService(workspace: fixture.workspace, jobs: jobs)
    var began = false
    _ = try jobs.start(name: "metadata.search") { _ in
        began = true
        try await Task.sleep(for: .seconds(60))
        return .null
    }
    while !began {
        await Task.yield()
    }
    #expect(throws: BridgeFailure.self) { try ContainerRegistry.acquire(fixture.workspace) }
    await service.shutdown()
    let lease = try ContainerRegistry.acquire(fixture.workspace)
    ContainerRegistry.release(lease)
}
