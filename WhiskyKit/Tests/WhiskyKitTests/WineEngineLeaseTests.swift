//
//  WineEngineLeaseTests.swift
//  WhiskyKit
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
@testable import WhiskyKit

/// Shared-lease lifetime: a retained ``WineOperationContext`` — in an
/// unstructured TaskLocal child or a spawned process — keeps the shared
/// lock until the holder dies, never released early by the parent scope.
@Suite("Wine engine lease lifetime")
@MainActor struct WineEngineLeaseTests {
    private func temporaryRoot(_ label: String = "lease") throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisky-\(label)-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeBottle(in root: URL, name: String) throws -> Bottle {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(
            at: url.appending(path: "drive_c/windows/system32"), withIntermediateDirectories: true
        )
        let bottle = Bottle(bottleUrl: url, inFlight: false, isAvailable: true)
        bottle.settings.name = name
        return bottle
    }

    /// A real executable that blocks forever — never Wine. Platform binaries
    /// (`/bin/sleep` & co.) are SIGKILLed when copied out of `/bin`, so the
    /// `wine64` loader is a one-line C fixture compiled at test time; the
    /// toolchain is guaranteed present — it built this package.
    private func makeSleepEngine(at root: URL) throws {
        let bin = root.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appending(path: "lib"), withIntermediateDirectories: true
        )
        let source = root.appending(path: "sleeper.c")
        try "#include <unistd.h>\nint main(void) { for (;;) { pause(); } return 0; }\n"
            .write(to: source, atomically: true, encoding: .utf8)
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compile.arguments = [
            "-O2", "-o", bin.appending(path: "wine64").path(percentEncoded: false),
            source.path(percentEncoded: false)
        ]
        try compile.run()
        compile.waitUntilExit()
        guard compile.terminationStatus == 0 else {
            throw WineEngineError.engineUnavailable("fixture sleeper failed to compile")
        }
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"), to: bin.appending(path: "wineserver")
        )
    }

    private func withStore<T>(
        _ store: WineEngineStore, _ body: () throws -> T
    ) rethrows -> T {
        try Wine.$engineStoreOverride.withValue(store, operation: body)
    }

    private func expectExclusiveRefused(
        prefixURL: URL, registryURL: URL, _ comment: Comment
    ) {
        #expect(throws: WineEngineError.self, comment) {
            _ = try WineEngineLease.acquireHandle(
                prefixURL: prefixURL, registryURL: registryURL, exclusive: true
            )
        }
    }

    /// Polls until an exclusive lease succeeds or `timeout` elapses.
    private func awaitExclusiveLease(
        prefixURL: URL, registryURL: URL, timeout: TimeInterval = 5
    ) async -> WineEngineLease.LeaseHandle? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let lease = try? WineEngineLease.acquireHandle(
                prefixURL: prefixURL, registryURL: registryURL, exclusive: true
            ) {
                return lease
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    // MARK: - Mutual exclusion

    /// A shared lease refuses an exclusive one; an exclusive lease makes an
    /// operation fail at the lease — before it even resolves the engine, so
    /// an unregistered engine id would surface `engineUnavailable`, not busy.
    @Test func sharedBlocksExclusiveAndExclusiveBlocksOperationBeforeResolution() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WineEngineStore(registryURL: root.appending(path: "engines.json")) { [] }
        let bottle = try makeBottle(in: root, name: "Bottle")

        let shared = try WineEngineLease.acquireHandle(
            prefixURL: bottle.url, registryURL: store.registryURL, exclusive: false
        )
        expectExclusiveRefused(
            prefixURL: bottle.url, registryURL: store.registryURL,
            "exclusive must be refused while a shared lease is held"
        )
        shared.release()

        // Bound to an id the store has never registered: if the operation
        // resolved the engine before leasing it would throw
        // `engineUnavailable`. It must refuse with `operationBusy` instead.
        bottle.settings.wineEngineID = "no-such-engine"
        let exclusive = try WineEngineLease.acquireHandle(
            prefixURL: bottle.url, registryURL: store.registryURL, exclusive: true
        )
        do {
            try await Wine.$engineStoreOverride.withValue(store) {
                try await Wine.withEngineOperation(bottle: bottle) {}
            }
            Issue.record("operation must refuse while an exclusive lease is held")
        } catch let error as WineEngineError {
            guard case .operationBusy = error else {
                Issue.record("expected operationBusy before resolution, got \(error)")
                return
            }
        }
        exclusive.release()
    }

    // MARK: - TaskLocal child retention

    /// An unstructured `Task` spawned inside an operation inherits the pinned
    /// context. The parent scope returning must NOT free the shared lease —
    /// the child holds it until the child (and its task-local storage) dies.
    @Test func inheritedContextKeepsSharedLeaseAfterParentReturns() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WineEngineStore(registryURL: root.appending(path: "engines.json")) { [] }
        try makeSleepEngine(at: root.appending(path: "engine"))
        let engine = try store.register(at: root.appending(path: "engine"), name: "E")
        let bottle = try makeBottle(in: root, name: "Bottle")
        bottle.settings.wineEngineID = engine.id

        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
        var child: Task<Void, Never>?
        try await Wine.$engineStoreOverride.withValue(store) {
            // The sync overload shares the same context/lease path; the
            // unstructured Task inherits the TaskLocal either way.
            try Wine.withEngineOperation(bottle: bottle) {
                // Unstructured Task inherits the operation TaskLocal — the
                // context (and its lease) now lives in the child's storage.
                child = Task {
                    for await _ in gate {}
                }
            }
        }

        // Parent returned; child still parked on the gate.
        try await Task.sleep(nanoseconds: 50_000_000)
        expectExclusiveRefused(
            prefixURL: bottle.url, registryURL: store.registryURL,
            "child's inherited context must keep the shared lease"
        )

        gateContinuation.finish()
        await child?.value
        // Task-local storage dies with the Task object, not with its
        // completion — drop our reference so the inherited context (and the
        // lease it retains) is destroyed before asserting the unlock.
        child = nil
        let lease = await awaitExclusiveLease(
            prefixURL: bottle.url, registryURL: store.registryURL
        )
        #expect(lease != nil, "exclusive must succeed once the child's context dies")
        lease?.release()
    }

    // MARK: - Process retention

    /// A spawned process binds the shared lease to real exit: while the child
    /// is alive an exclusive acquisition is refused; only the observed
    /// `waitUntilExit` — after stream cancellation terminates the fixture —
    /// frees the lock. Never Wine: `wine64` here is a copied `/bin/sleep`.
    @Test func spawnedProcessHoldsSharedLeaseUntilObservedExit() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WineEngineStore(registryURL: root.appending(path: "engines.json")) { [] }
        try makeSleepEngine(at: root.appending(path: "engine"))
        let engine = try store.register(at: root.appending(path: "engine"), name: "Sleeper")
        let bottle = try makeBottle(in: root, name: "Bottle")
        bottle.settings.wineEngineID = engine.id

        let stream = try Wine.$logsFolderOverride.withValue(root) {
            try withStore(store) {
                try Wine.runWineProcess(name: "fixture-sleep", args: ["60"], bottle: bottle)
            }
        }
        // `.started` yields when iteration begins; give the fixture a moment
        // to exec before asserting the lock.
        let consumer = Task {
            for await _ in stream {}
        }
        try await Task.sleep(nanoseconds: 300_000_000)

        expectExclusiveRefused(
            prefixURL: bottle.url, registryURL: store.registryURL,
            "exclusive must be refused while the spawned process is alive"
        )

        // Cancelling iteration terminates the child (Process.runStream's
        // onTermination -> terminate()); the lease waiter observes the real
        // exit before the lock frees.
        consumer.cancel()
        _ = await consumer.value

        let lease = await awaitExclusiveLease(
            prefixURL: bottle.url, registryURL: store.registryURL
        )
        #expect(lease != nil, "exclusive must succeed after the process is observed dead")
        lease?.release()
    }
}
