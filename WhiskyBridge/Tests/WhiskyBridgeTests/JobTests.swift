//
//  JobTests.swift
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
import Testing
@testable import WhiskyApplication
import WhiskyBridgeProtocol

@MainActor private func waitForJob(_ store: BridgeJobStore, _ id: String, status: String) async throws -> JSONValue {
    for _ in 0 ..< 2_000 {
        let snapshot = try store.call("jobs.get", params: ["jobID": .string(id)])
        if snapshot.object?["status"] == .string(status) {
            return snapshot
        }
        await Task.yield()
    }
    throw BridgeFailure("test_timeout", "Job did not reach \(status)")
}

@Test @MainActor func jobsRetainProgressResultAndStructuredFailure() async throws {
    let store = BridgeJobStore()
    let started = try store.start(name: "fixture", extra: [
        "backend": .string("DXMT"),
        "jobID": .string("invalid")
    ]) { progress in
        progress(.object(["stage": .string("loaded")]))
        return .string("result")
    }
    let id = try #require(started.object?["jobID"]?.string)
    #expect(id != "invalid")
    #expect(started.object?["backend"] == .string("DXMT"))
    let done = try await waitForJob(store, id, status: "completed")
    #expect(done.object?["result"] == .string("result"))
    #expect(done.object?["progress"]?.object?["stage"] == .string("loaded"))
    let failed = try store.start(name: "failure") { _ in throw BridgeFailure("fixture_error", "fixture") }
    let failedID = try #require(failed.object?["jobID"]?.string)
    let failure = try await waitForJob(store, failedID, status: "failed")
    #expect(failure.object?["error"]?.object?["code"] == .string("fixture_error"))
}

@Test @MainActor func cancellationWaitsForUnwindAndDiscardsLateSuccess() async throws {
    let store = BridgeJobStore()
    var resume: CheckedContinuation<Void, Never>?
    let started = try store.start(name: "fixture") { _ in
        await withCheckedContinuation { resume = $0 }
        return .string("late success")
    }
    let id = try #require(started.object?["jobID"]?.string)
    _ = try await waitForJob(store, id, status: "running")
    let cancelling = try store.call("jobs.cancel", params: ["jobID": .string(id)])
    #expect(cancelling.object?["status"] == .string("cancelling"))
    resume?.resume()
    let cancelled = try await waitForJob(store, id, status: "cancelled")
    #expect(cancelled.object?["result"] == .null)
    #expect(cancelled.object?["error"]?.object?["code"] == .string("cancelled"))
    await store.shutdown()
}

@Test @MainActor func jobsBoundActiveOperationsAndDrainOnShutdown() async throws {
    let store = BridgeJobStore()
    for _ in 0 ..< 32 {
        _ = try store.start(name: "wait") { _ in
            try await Task.sleep(for: .seconds(60))
            return .null
        }
    }
    #expect(throws: BridgeFailure.self) { try store.start(name: "overflow") { _ in .null } }
    await store.shutdown()
    let next = try store.start(name: "after eviction") { progress in
        progress(.string(String(repeating: "a", count: 20_000)))
        return .bool(true)
    }
    let id = try #require(next.object?["jobID"]?.string)
    let done = try await waitForJob(store, id, status: "completed")
    #expect(done.object?["progress"]?.object?["truncated"] == .bool(true))
}
