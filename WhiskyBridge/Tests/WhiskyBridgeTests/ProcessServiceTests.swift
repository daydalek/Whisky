//
//  ProcessServiceTests.swift
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
import WhiskyCore

/// Rows come from this stub, so the tests assert the wire shape, never a
/// specific PID. One row borrows a live system process for its pid value.
@MainActor
private final class StubProcessHost: ProcessSnapshotProviding {
    var rows: [ProcessRecord]
    var terminations: [(pid: Int32, force: Bool)] = []

    init(rows: [ProcessRecord]) {
        self.rows = rows
    }

    func listProcesses(in container: URL) async throws -> [ProcessRecord] {
        rows
    }

    func terminateProcess(in container: URL, pid: Int32, force: Bool) async throws {
        terminations.append((pid, force))
        rows.removeAll { $0.pid == pid }
    }
}

@MainActor
private func fixture() throws -> (root: URL, container: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("whisky-procs-\(UUID())")
    let container = root.appendingPathComponent("Bottle")
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    let metadata: [String: Any] = ["info": ["name": "Processes", "pins": [], "blocklist": []]]
    try PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0)
        .write(to: container.appendingPathComponent("Metadata.plist"))
    return (root, container)
}

@MainActor
private func stubRows() -> [ProcessRecord] {
    let live = HostProcessIdentityProvider().currentProcess.pid
    return [
        ProcessRecord(
            pid: live,
            name: "game.exe",
            memory: "24 K",
            kind: "app",
            source: "whisky",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            macosPID: live
        ),
        ProcessRecord(pid: 4242, name: "services.exe", memory: "1,024 K", kind: "service", source: "untracked")
    ]
}

@Test @MainActor func processMethodsAreAdvertisedInTheHelperAllowList() async {
    let service = ApplicationService(workspace: ApplicationWorkspace(containers: []))
    let describe = await service.respond(.init(id: "1", method: "bridge.describe"))
    let values: [JSONValue]
    if case let .array(rows) = describe.result?.object?["methods"] {
        values = rows
    } else {
        values = []
    }
    let methods = values.compactMap(\.string)
    #expect(methods.contains("processes.list"))
    #expect(methods.contains("processes.kill"))
    for method in ProcessService.methods {
        #expect(ApplicationService.methods.contains(method))
    }
}

@Test @MainActor func processListReturnsAWellFormedArray() async throws {
    let (root, container) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let host = StubProcessHost(rows: stubRows())
    let service = ApplicationService(
        workspace: ApplicationWorkspace(containers: [container]),
        processes: ProcessService(host: host)
    )
    let reply = try await service.call("processes.list", params: ["container": .string(container.path)])
    guard case let .array(rows) = reply else {
        Issue.record("processes.list did not return an array")
        return
    }
    #expect(rows.count == 2)
    for row in rows {
        #expect(row.object?["pid"]?.integer != nil)
        #expect(row.object?["name"]?.string?.isEmpty == false)
        #expect(row.object?["memory"]?.string != nil)
        #expect(row.object?["kind"]?.string != nil)
        #expect(row.object?["source"]?.string != nil)
    }
    #expect(rows[0].object?["kind"] == .string("app"))
    #expect(rows[0].object?["source"] == .string("whisky"))
    #expect(rows[0].object?["startedAt"] == .number(1_700_000_000))
    #expect(rows[0].object?["macosPid"]?.integer != nil)
    // Untracked rows carry no launch time and no macOS PID.
    #expect(rows[1].object?["startedAt"] == .null)
    #expect(rows[1].object?["macosPid"] == .null)
    #expect(rows[1].object?["kind"] == .string("service"))
}

@Test @MainActor func processKillReportsKilledForALivePidAndFalseForABogusOne() async throws {
    let (root, container) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let host = StubProcessHost(rows: stubRows())
    let service = ApplicationService(
        workspace: ApplicationWorkspace(containers: [container]),
        processes: ProcessService(host: host)
    )
    let params: [String: JSONValue] = ["container": .string(container.path)]

    // A PID the snapshot never saw: `killed: false`, no throw.
    var bogus = params
    bogus["pid"] = .integer(999_999_999)
    let missed = try await service.call("processes.kill", params: bogus)
    #expect(missed.object?["killed"] == .bool(false))
    #expect(host.terminations.isEmpty)

    // A live row: the graceful path is dispatched and the reply is `true`.
    var graceful = params
    graceful["pid"] = .integer(4242)
    let killed = try await service.call("processes.kill", params: graceful)
    #expect(killed.object?["killed"] == .bool(true))
    #expect(host.terminations.map(\.pid) == [4242])
    #expect(host.terminations.map(\.force) == [false])

    // `force` selects the hard path.
    let live = try #require(stubRows().first?.pid)
    var forced = params
    forced["pid"] = .integer(Int64(live))
    forced["force"] = .bool(true)
    let hard = try await service.call("processes.kill", params: forced)
    #expect(hard.object?["killed"] == .bool(true))
    #expect(host.terminations.map(\.force) == [false, true])
}
