//
//  ProcessService.swift
//  WhiskyApplication
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
import WhiskyBridgeProtocol
import WhiskyCore

/// One process row, mirroring the columns `RunningProcessesView` displays.
///
/// Fields the SwiftUI view cannot show honestly are deliberately absent: the
/// tasklist snapshot carries a display string for memory (`"24 K"`), not a
/// byte count, and no CPU percentage at all.
public struct ProcessRecord: Sendable, Equatable {
    /// The Wine/Windows PID from the snapshot.
    public let pid: Int32
    /// The Windows image name (e.g. `"game.exe"`).
    public let name: String
    /// The raw tasklist memory string (e.g. `"24 K"`).
    public let memory: String
    /// `app`, `service` or `system` (`ProcessKind.rawValue`).
    public let kind: String
    /// `whisky` for registry-tracked processes, `untracked` otherwise
    /// (`ProcessSource.rawValue`).
    public let source: String
    /// Launch time from the process registry match; nil for untracked rows.
    public let startedAt: Date?
    /// The macOS PID of the host process, when the registry knows it.
    public let macosPID: Int32?

    public init(
        pid: Int32,
        name: String,
        memory: String,
        kind: String,
        source: String,
        startedAt: Date? = nil,
        macosPID: Int32? = nil
    ) {
        self.pid = pid
        self.name = name
        self.memory = memory
        self.kind = kind
        self.source = source
        self.startedAt = startedAt
        self.macosPID = macosPID
    }
}

/// The host effects `ProcessService` delegates to. The macOS adapter reuses
/// `Wine.listProcesses` and `Wine.gracefulKillProcess` / `Wine.forceKillProcess`
/// exactly as the SwiftUI Processes page drives them.
@MainActor
public protocol ProcessSnapshotProviding: AnyObject {
    /// One snapshot of the container's Windows processes.
    func listProcesses(in container: URL) async throws -> [ProcessRecord]
    /// Deliver one termination request (`taskkill.exe`, with `/F` when `force`).
    func terminateProcess(in container: URL, pid: Int32, force: Bool) async throws
    /// Terminate all processes running in the container.
    func terminateAllProcesses(in container: URL) async throws
}

/// Portable bridge adapter for `processes.list` and `processes.kill`.
///
/// Kill semantics mirror `ProcessesViewModel`: a graceful `taskkill.exe` by
/// default, the force path (`/F`) behind `force`. The reply's `killed` reports
/// whether the snapshot saw the PID and the request was dispatched — the same
/// observation the SwiftUI refresh loop makes after a kill. A PID the snapshot
/// does not contain is answered `killed: false` without an error.
@MainActor
public final class ProcessService {
    public static let methods = ["processes.list", "processes.kill", "processes.killAll"]

    private let host: (any ProcessSnapshotProviding)?

    public init(host: (any ProcessSnapshotProviding)? = nil) {
        self.host = host
    }

    public func call(
        _ method: String,
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) async throws -> JSONValue {
        guard let host else { throw BridgeFailure(
            "method_unavailable",
            "Process methods require the Wine host adapter"
        ) }
        guard Self.methods.contains(method) else { throw BridgeFailure(
            "method_unavailable",
            "Process method is unavailable: \(method)"
        ) }
        let container = try workspace.resolve(params)
        switch method {
        case "processes.list":
            return try await list(host: host, container: container)
        case "processes.kill":
            return try await kill(host: host, container: container, params: params)
        case "processes.killAll":
            try await host.terminateAllProcesses(in: container)
            return .object(["accepted": .bool(true)])
        default:
            throw BridgeFailure("method_unavailable", "Process method is unavailable: \(method)")
        }
    }

    private func list(host: any ProcessSnapshotProviding, container: URL) async throws -> JSONValue {
        .array(try await host.listProcesses(in: container).map { record in
            .object([
                "pid": .integer(Int64(record.pid)),
                "name": .string(record.name),
                "memory": .string(record.memory),
                "kind": .string(record.kind),
                "source": .string(record.source),
                "startedAt": record.startedAt.map { .number($0.timeIntervalSince1970) } ?? .null,
                "macosPid": record.macosPID.map { .integer(Int64($0)) } ?? .null
            ])
        })
    }

    private func kill(
        host: any ProcessSnapshotProviding,
        container: URL,
        params: [String: JSONValue]
    ) async throws -> JSONValue {
        let pid: Int32
        switch params["pid"] {
        case let .integer(value):
            guard let parsed = Int32(exactly: value) else { throw BridgeFailure(
                "invalid_params",
                "PID is out of range"
            ) }
            pid = parsed
        default: throw BridgeFailure("invalid_params", "Expected integer: pid")
        }
        let force = params["force"] == nil ? false : try params.flag("force")
        // The snapshot is the same observation the kill targets: a PID that is
        // not in it cannot be signalled, and the reply says so instead of
        // throwing.
        let processes = try await host.listProcesses(in: container)
        guard processes.contains(where: { $0.pid == pid }) else {
            return .object(["killed": .bool(false)])
        }
        try await host.terminateProcess(in: container, pid: pid, force: force)
        return .object(["killed": .bool(true)])
    }
}
