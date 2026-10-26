//
//  BridgeJobStore.swift
//  WhiskyCore
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

/// Retained operations let the UI keep polling, cancelling and navigating while work continues.
@MainActor
public final class BridgeJobStore {
    public typealias Progress = @MainActor (JSONValue) -> Void
    public typealias Operation = @MainActor (@escaping Progress) async throws -> JSONValue
    private struct Record {
        let name: String
        var status = "queued"
        var progress: JSONValue = .null
        var result: JSONValue?
        var error: BridgeFailure?
    }

    private var records: [String: Record] = [:]
    private var order: [String] = []
    private var tasks: [String: Task<Void, Never>] = [:]
    var workspace: ApplicationWorkspace?
    var hasActiveOperations: Bool {
        !tasks.isEmpty
    }

    var hasLifecycleOperation: Bool {
        tasks.keys.contains {
            records[$0]?.name.hasPrefix("bottle.") == true || records[$0]?.name == "workspace.recover"
        }
    }

    public init() {}
    public func start(
        name: String,
        extra: [String: JSONValue] = [:],
        operation: @escaping Operation
    ) throws -> JSONValue {
        while records.count >= 32, let index = order.firstIndex(where: { tasks[$0] == nil }) {
            records[order.remove(at: index)] = nil
        }
        guard records.count < 32 else { throw BridgeFailure("busy", "Operation queue is full", retryable: true) }
        let id = UUID().uuidString
        records[id] = Record(name: name)
        order.append(id)
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                let lease: Int32? = if let workspace,
                                       !name.hasPrefix("bottle."), name != "workspace.recover" {
                    try ContainerRegistry.acquireShared(workspace)
                } else {
                    nil
                }
                defer {
                    if let lease {
                        ContainerRegistry.release(lease)
                    }
                }
                records[id]?.status = "running"
                let result = try await operation { [weak self] progress in
                    guard let self, records[id]?.status == "running" else { return }
                    let size = (try? JSONEncoder().encode(progress).count) ?? .max
                    records[id]?.progress = size <= 16_384 ? progress : .object(["truncated": .bool(true)])
                }
                try Task.checkCancellation()
                records[id]?.result = result
                records[id]?.status = "completed"
            } catch {
                if Task.isCancelled || error is CancellationError {
                    records[id]?.status = "cancelled"
                    records[id]?.error = BridgeFailure(
                        "cancelled",
                        "Operation cancelled; reload affected state before retrying"
                    )
                } else {
                    records[id]?.status = "failed"
                    records[id]?.error = error as? BridgeFailure ?? BridgeFailure(
                        "operation_failed",
                        error.localizedDescription
                    )
                }
            }
            tasks[id] = nil
        }
        var payload = extra
        payload["jobID"] = .string(id)
        return .object(payload)
    }

    public func call(_ method: String, params: [String: JSONValue]) throws -> JSONValue {
        let id = try params.text("jobID")
        guard records[id] != nil else { throw BridgeFailure("unknown_job", "Operation is no longer retained") }
        if method == "jobs.cancel", let task = tasks[id] {
            records[id]?.status = "cancelling"
            task.cancel()
        }
        guard let record = records[id] else { throw BridgeFailure("unknown_job", "Operation is no longer retained") }
        return try .object([
            "jobID": .string(id),
            "name": .string(record.name),
            "status": .string(record.status),
            "progress": record.progress,
            "result": record.result ?? .null,
            "error": record.error.map(JSONValue.encoded) ?? .null
        ])
    }

    public func shutdown() async {
        let running = Array(tasks.values)
        for task in running {
            task.cancel()
        }
        for task in running {
            await task.value
        }
    }
}
