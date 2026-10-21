//
//  ActivityHostAdapterTests.swift
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
import Synchronization
import Testing
import WhiskyCore
@testable import WhiskyKit

@Suite("Activity host adapters")
struct ActivityHostAdapterTests {
    private func entry(_ root: URL) -> LibraryEntry {
        LibraryEntry(
            id: "game",
            name: "Game",
            iconURL: nil,
            bottleURL: root,
            source: .pinned,
            launch: .program(root.appendingPathComponent("game.exe"))
        )
    }

    @Test func injectedProcessesControlLeaseIdentityAndRecycledPIDTakeover() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstProcess = HostProcessIdentity(pid: 123, birth: 100)
        let secondProcess = HostProcessIdentity(pid: 123, birth: 200)
        let first = GameActivityStore(processes: FixedProcesses(currentProcess: firstProcess))
        let game = entry(root)
        let owner = try first.acquireOwnership(for: game, source: .gui)
        #expect(owner.process == firstProcess)
        let second = GameActivityStore(processes: FixedProcesses(currentProcess: secondProcess))
        let successor = try second.acquireOwnership(for: game, source: .gui)
        #expect(successor.generation == owner.generation + 1)
        #expect(successor.process == secondProcess)
        let contender = GameActivityStore(processes: FixedProcesses(currentProcess: firstProcess, alive: secondProcess))
        #expect(throws: GameActivityStore.OwnershipError.heldByLiveOwner(successor)) {
            try contender.acquireOwnership(for: game, source: .cli)
        }
        #expect(try second.load(for: game).owner == successor)
    }

    @Test func failedLockPreservesFilesAndRatingRetainsItsCocoaError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let game = entry(root)
        let store = GameActivityStore(locking: UnavailableLock())
        #expect(throws: CocoaError(.fileWriteNoPermission)) { try store.setRating(5, for: game) }
        do {
            try store.setRating(11, for: game)
            Issue.record("Expected rating validation")
        } catch {
            let error = error as NSError
            #expect(error.domain == NSCocoaErrorDomain && error.code == 1_610)
        }
        #expect(FileManager.default.fileExists(atPath: root.path) == false)
    }

    @Test func retriesAndOldCallbacksKeepNotificationAndDiskStateStable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GameActivityStore()
        let game = entry(root)
        let updates = Mutex<[String]>([])
        let observer = NotificationCenter.default.addObserver(
            forName: GameActivityStore.didUpdateNotification, object: store, queue: nil
        ) { update in
            if let id = update.userInfo?[GameActivityStore.entryIDKey] as? String {
                updates.withLock { $0.append(id) }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let owner = try store.acquireOwnership(for: game, source: .gui)
        #expect(try store.acquireOwnership(for: game, source: .gui, ownerID: owner.ownerID) == owner)
        let date = Date(timeIntervalSince1970: 100)
        #expect(try store.recordSample(
            seconds: 10,
            at: date,
            for: game,
            ownerID: owner.ownerID,
            generation: owner.generation,
            sequence: 1
        ) == .applied(playTime: 10))
        #expect(try store.recordSample(
            seconds: 10,
            at: date,
            for: game,
            ownerID: owner.ownerID,
            generation: owner.generation,
            sequence: 1
        ) == .alreadyApplied)
        #expect(try store.completeSession(
            for: game,
            at: date,
            ownerID: owner.ownerID,
            generation: owner.generation + 1
        ) == false)
        #expect(updates.withLock { $0 } == [game.id, game.id])
        #expect(try store.completeSession(for: game, at: date, ownerID: owner.ownerID, generation: owner.generation))
        #expect(updates.withLock { $0.count } == 3)
        let saved = try store.load(for: game)
        #expect(saved.playTime == 10 && saved.lastSessionEndedAt == date && saved.owner == nil)
    }

    @Test func nativeLocksSerializeUpdatesAndReleaseAfterThrows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let locker = MacOSActivityFileLock()
        let lock = root.appendingPathComponent("counter.lock")
        let counter = root.appendingPathComponent("counter.txt")
        #expect(throws: CocoaError(.fileWriteUnknown)) {
            try locker.withExclusiveLock(at: lock) { throw CocoaError(.fileWriteUnknown) }
        }
        let failures = Mutex<[String]>([])
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            do {
                try locker.withExclusiveLock(at: lock) {
                    let count = (try? String(contentsOf: counter, encoding: .utf8)).flatMap(Int.init) ?? 0
                    Thread.sleep(forTimeInterval: 0.001)
                    try String(count + 1).write(to: counter, atomically: false, encoding: .utf8)
                }
            } catch {
                failures.withLock { $0.append(error.localizedDescription) }
            }
        }
        #expect(failures.withLock { $0 }.isEmpty)
        #expect(try String(contentsOf: counter, encoding: .utf8) == "20")
        let owner = GameActivityOwner(source: .gui)
        #expect(owner.hostPID == ProcessInfo.processInfo.processIdentifier)
        #expect(GameActivityStore.isProcessAlive(pid: owner.hostPID, birth: owner.hostProcessBirth))
    }
}

private struct FixedProcesses: ProcessIdentityProviding {
    let currentProcess: HostProcessIdentity
    var alive: HostProcessIdentity?
    func isAlive(_ process: HostProcessIdentity) -> Bool {
        process == alive
    }
}

private struct UnavailableLock: ActivityFileLocking {
    func withExclusiveLock<Result>(at url: URL, operation: () throws -> Result) throws -> Result {
        throw CocoaError(.fileWriteNoPermission)
    }
}
