//
//  FileDiagnosticsTests.swift
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
#if os(Linux)
import Glibc
#elseif os(macOS)
import Darwin
#endif

@Test @MainActor func fileDiagnosticsReportsReadOnlyHostAndContainerChecks() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let marker = fixture.source.appendingPathComponent("Metadata.plist")
    let before = try Data(contentsOf: marker)
    let registry = try Data(contentsOf: fixture.registry)
    let report = try await fixture.run("bottle.diagnostics").object?["report"]?.string
    #expect(report?.contains("Whisky file diagnostics v1") == true)
    #expect(report?.contains("Architecture:") == true)
    #expect(report?.contains("Pinned entries: 1") == true)
    #expect(report?.contains("Name: Original") == true)
    let checks = try await fixture.run("bottle.checks").object?["checks"]
    guard case let .array(values) = checks else { Issue.record("Expected checks")
        return
    }
    #expect(values.count == 4)
    #expect(values[0].object?["outcome"] == .string("pass"))
    #expect(values[1].object?["outcome"] == .string("pass"))
    #expect(try Data(contentsOf: marker) == before)
    #expect(try Data(contentsOf: fixture.registry) == registry)
}

@Test @MainActor func fileDiagnosticsRejectsSymlinkAndFIFOWithoutReadingTheirContents() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let marker = fixture.source.appendingPathComponent("Metadata.plist")
    let external = fixture.root.appendingPathComponent("External.plist")
    try FileManager.default.moveItem(at: marker, to: external)
    try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: external)
    let report = try await fixture.run("bottle.diagnostics").object?["report"]?.string
    #expect(report?.contains("Name: unreadable") == true)
    #expect(report?.contains("host.container_metadata: warning") == true)
    try FileManager.default.removeItem(at: marker)
    #expect(mkfifo(marker.path, mode_t(0o600)) == 0)
    let fifo = try await fixture.run("bottle.diagnostics").object?["report"]?.string
    #expect(fifo?.contains("Name: unreadable") == true)
    #expect(FileManager.default.fileExists(atPath: external.path))
}

@Test @MainActor func fileDiagnosticsExportsPrivateCompleteReportAndPreservesExistingTargets() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let destination = fixture.root.appendingPathComponent("中文 Report.txt")
    let params: [String: JSONValue] = ["destination": .string(destination.path)]
    let result = try await fixture.run("bottle.exportDiagnostics", params)
    #expect(result.object?["path"] == .string(destination.path))
    let report = try Data(contentsOf: destination)
    #expect(String(bytes: report, encoding: .utf8)?.contains("File checks") == true)
    let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    await #expect(throws: (any Error).self) { try await fixture.run("bottle.exportDiagnostics", params) }
    #expect(try Data(contentsOf: destination) == report)
    let alias = fixture.root.appendingPathComponent("Alias.txt")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: destination)
    await #expect(throws: (any Error).self) {
        try await fixture.run("bottle.exportDiagnostics", ["destination": .string(alias.path)])
    }
    #expect(try Data(contentsOf: destination) == report)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        .allSatisfy { !$0.hasPrefix(".whisky-diagnostics-") })
}

@Test @MainActor func fileDiagnosticsHonorsRegistryLeaseRecoveryAndDestinationBoundaries() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    for destination in [fixture.registry, fixture.source.appendingPathComponent("report.txt")] {
        await #expect(throws: (any Error).self) {
            try await fixture.run("bottle.exportDiagnostics", ["destination": .string(destination.path)])
        }
    }
    let lease = try ContainerRegistry.acquire(fixture.workspace)
    await #expect(throws: (any Error).self) { try await fixture.run("bottle.diagnostics") }
    ContainerRegistry.release(lease)
    let journal = fixture.registry.appendingPathExtension("lifecycle.plist")
    try Data("retained recovery".utf8).write(to: journal)
    await #expect(throws: (any Error).self) { try await fixture.run("bottle.diagnostics") }
    #expect(try Data(contentsOf: journal) == Data("retained recovery".utf8))
}
