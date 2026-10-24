//
//  ExportRecoveryTests.swift
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

private func exportRecord(_ fixture: LifecycleFixture, prepared: Bool = false) throws -> ExportJournal {
    let temporary = fixture.root.appendingPathComponent(".whisky-export-" + UUID().uuidString)
    try Data("derived archive fixture".utf8).write(to: temporary)
    var record = try ExportJournal(
        source: fixture.source,
        destination: fixture.root.appendingPathComponent("archive.tar"),
        temporary: temporary
    )
    record.prepared = prepared
    try record.save(fixture.registry)
    return record
}

@Test @MainActor func exportRecoveryRemovesPartialArchiveAndPreservesSourceAndRegistry() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let before = try Data(contentsOf: fixture.registry)
    let record = try exportRecord(fixture)
    let result = try await fixture.run("workspace.recover")
    #expect(result.object?["outcome"] == .string("rolled_back"))
    #expect(!FileManager.default.fileExists(atPath: record.temporary.path))
    #expect(!ContainerJournal.pending(fixture.registry))
    #expect(try Data(contentsOf: fixture.registry) == before)
    #expect(try String(contentsOf: fixture.executable, encoding: .utf8) == "fixture game")
}

@Test @MainActor func exportRecoveryRetainsPublishedArchiveAcrossTheCleanupBoundary() async throws {
    for temporaryAlreadyRemoved in [false, true] {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanup() }
        let record = try exportRecord(fixture, prepared: true)
        try FileManager.default.linkItem(at: record.temporary, to: record.destination)
        if temporaryAlreadyRemoved {
            try FileManager.default.removeItem(at: record.temporary)
        }
        let result = try await fixture.run("workspace.recover")
        #expect(result.object?["outcome"] == .string("published"))
        #expect(try Data(contentsOf: record.destination) == Data("derived archive fixture".utf8))
        #expect(!FileManager.default.fileExists(atPath: record.temporary.path))
        #expect(!ContainerJournal.pending(fixture.registry))
    }
}

@Test @MainActor func exportRecoveryPreservesForeignDestinationsAndRejectsReplacedTemporaryFiles() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let record = try exportRecord(fixture, prepared: true)
    try FileManager.default.createDirectory(at: record.destination, withIntermediateDirectories: false)
    let marker = record.destination.appendingPathComponent("foreign")
    try Data("foreign data".utf8).write(to: marker)
    _ = try await fixture.run("workspace.recover")
    #expect(try Data(contentsOf: marker) == Data("foreign data".utf8))
    let replaced = try exportRecord(fixture)
    let retained = fixture.root.appendingPathComponent("retained-old-temporary")
    try FileManager.default.moveItem(at: replaced.temporary, to: retained)
    try Data("new user data".utf8).write(to: replaced.temporary)
    await #expect(throws: BridgeFailure.self) { try await fixture.run("workspace.recover") }
    #expect(try Data(contentsOf: replaced.temporary) == Data("new user data".utf8))
    #expect(ContainerJournal.pending(fixture.registry))
}

@Test @MainActor func exportJournalBlocksOtherContainerWritesAndPreservesCorruptEvidence() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let url = ExportJournal.location(fixture.registry)
    try Data("corrupt export journal".utf8).write(to: url)
    await #expect(throws: BridgeFailure.self) {
        try await fixture.run("bottle.rename", ["name": .string("Blocked")])
    }
    await #expect(throws: BridgeFailure.self) { try await fixture.run("workspace.recover") }
    #expect(try Data(contentsOf: url) == Data("corrupt export journal".utf8))
}
