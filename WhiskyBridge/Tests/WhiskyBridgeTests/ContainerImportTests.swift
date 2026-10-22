//
//  ContainerImportTests.swift
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

@Test @MainActor func discoveryDeduplicatesAliasesAndPreservesSourceBytes() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let orphan = fixture.root.appendingPathComponent("Orphan")
    try FileManager.default.copyItem(at: fixture.source, to: orphan)
    let alias = fixture.root.appendingPathComponent("Alias")
    try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: orphan.path)
    let before = try Data(contentsOf: orphan.appendingPathComponent("Metadata.plist"))
    let registry = try Data(contentsOf: fixture.registry)
    let result = try await fixture.service().call("workspace.discover", params: ["path": .string(fixture.root.path)])
    guard case let .array(candidates) = result else { Issue.record("Expected discovery array")
        return
    }
    #expect(candidates.count == 1)
    #expect(candidates.first?.object?["path"] == .string(ContainerRegistry.canonical(orphan).path))
    #expect(try Data(contentsOf: fixture.registry) == registry)
    let params = try #require(candidates.first?.object)
    let imported = try await fixture.service().call("workspace.import", params: params)
    #expect(imported.object?["imported"] == .integer(1))
    #expect(try Data(contentsOf: orphan.appendingPathComponent("Metadata.plist")) == before)
    #expect(try (fixture.read(fixture.registry)["futureRegistry"] as? [String: Bool])?["retain"] == true)
    let again = try await fixture.service().call("workspace.import", params: ["path": .string(alias.path)])
    #expect(again.object?["imported"] == .integer(0))
    #expect(try fixture.workspace.containers().count == 2)
}

@Test @MainActor func importCreatesMissingRegistryAndValidatesCompleteBatchBeforeWriting() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    try FileManager.default.removeItem(at: fixture.registry)
    let service = fixture.service()
    await #expect(throws: (any Error).self) {
        try await service.call("workspace.import", params: ["paths": .array([
            .string(fixture.source.path), .string(fixture.root.appendingPathComponent("Missing").path)
        ])])
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.registry.path))
    let result = try await service.call("workspace.import", params: ["path": .string(fixture.source.path)])
    #expect(result.object?["imported"] == .integer(1))
    #expect(try fixture.workspace.catalogue().first?.name == "Original")
}

@Test @MainActor func importRejectsStaleIdentityAndPendingRecoveryAndCorruptRegistry() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let before = try Data(contentsOf: fixture.registry)
    await #expect(throws: BridgeFailure.self) {
        try await fixture.service().call("workspace.import", params: [
            "path": .string(fixture.source.path), "device": .string("invalid"), "inode": .string("invalid")
        ])
    }
    #expect(try Data(contentsOf: fixture.registry) == before)
    let journal = ContainerJournal.location(fixture.registry)
    try Data("pending recovery".utf8).write(to: journal)
    await #expect(throws: BridgeFailure.self) {
        try await fixture.service().call("workspace.import", params: ["path": .string(fixture.source.path)])
    }
    try FileManager.default.removeItem(at: journal)
    try Data("corrupt registry".utf8).write(to: fixture.registry)
    await #expect(throws: (any Error).self) {
        try await fixture.service().call("workspace.import", params: ["path": .string(fixture.source.path)])
    }
    #expect(try Data(contentsOf: fixture.registry) == Data("corrupt registry".utf8))
}

@Test @MainActor func batchCandidateIdentitiesAreRevalidatedBeforeAnyRegistration() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let first = fixture.root.appendingPathComponent("First orphan")
    let second = fixture.root.appendingPathComponent("Second orphan")
    try FileManager.default.copyItem(at: fixture.source, to: first)
    try FileManager.default.copyItem(at: fixture.source, to: second)
    let candidates = try [first, second].map { try ContainerImportService.candidate($0, workspace: fixture.workspace) }
    let encoded = try JSONEncoder().encode(candidates)
    let request = try JSONDecoder().decode(JSONValue.self, from: encoded)
    let originalRegistry = try Data(contentsOf: fixture.registry)
    let retained = fixture.root.appendingPathComponent("Retained second")
    try FileManager.default.moveItem(at: second, to: retained)
    try FileManager.default.copyItem(at: fixture.source, to: second)
    await #expect(throws: BridgeFailure.self) {
        try await fixture.service().call("workspace.import", params: ["candidates": request])
    }
    #expect(try Data(contentsOf: fixture.registry) == originalRegistry)
    let refreshed = try [first, second].map { try ContainerImportService.candidate($0, workspace: fixture.workspace) }
    let freshRequest = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(refreshed))
    let result = try await fixture.service().call("workspace.import", params: ["candidates": freshRequest])
    #expect(result.object?["imported"] == .integer(2))
    #expect(try fixture.workspace.containers().count == 3)
    #expect(FileManager.default.fileExists(atPath: retained.appendingPathComponent("Metadata.plist").path))
}
