//
//  GameActivityStore.swift
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

import CoreData
import Foundation
import WhiskyCore

/// Serializes read-modify-write operations for ratings and process samples across processes.
public final class GameActivityStore: Sendable {
    public static let shared = GameActivityStore()
    public static let didUpdateNotification = Notification.Name("com.franke.Whisky.gameActivityStoreDidUpdate")
    public static let entryIDKey = "entryID"

    private let locking: any ActivityFileLocking
    private let processes: any ProcessIdentityProviding

    public init(
        locking: any ActivityFileLocking = MacOSActivityFileLock(),
        processes: any ProcessIdentityProviding = MacOSProcessIdentity()
    ) {
        self.locking = locking
        self.processes = processes
    }

    public typealias OwnershipError = GameActivityOwnershipError

    /// File locks and disk I/O execute outside the caller's actor.
    public func perform<T: Sendable>(_ operation: @escaping @Sendable (GameActivityStore) throws -> T) async throws
        -> T {
        try await Task.detached(priority: .utility) { try operation(self) }.value
    }

    public static func currentProcessBirth() -> UInt64 {
        MacOSProcessIdentity().currentProcess.birth
    }

    public static func isProcessAlive(pid: Int32, birth: UInt64? = nil) -> Bool {
        MacOSProcessIdentity().isAlive(HostProcessIdentity(pid: pid, birth: birth ?? 0))
    }

    private func withEntryLock<T>(for entry: LibraryEntry, block: () throws -> T) throws -> T {
        try locking.withExclusiveLock(at: lockLocation(for: entry), operation: block)
    }

    public func load(for entry: LibraryEntry) throws -> GameActivity {
        // Atomic replacement makes a read observe one complete JSON snapshot.
        try rawLoad(for: entry)
    }

    public func acquireOwnership(
        for entry: LibraryEntry,
        source: GameActivityOwner.Source,
        ownerID: UUID = UUID(),
        hostPID: Int32? = nil,
        hostProcessBirth: UInt64? = nil
    ) throws -> GameActivityOwner {
        let current = processes.currentProcess
        let process = HostProcessIdentity(pid: hostPID ?? current.pid, birth: hostProcessBirth ?? current.birth)
        return try withEntryLock(for: entry) {
            var activity = try rawLoad(for: entry)
            let previousOwner = activity.owner
            let newOwner = try activity.acquireOwnership(
                source: source, ownerID: ownerID,
                process: process,
                isAlive: { processes.isAlive($0) }
            )
            if newOwner != previousOwner {
                try rawSave(activity, for: entry)
            }
            return newOwner
        }
    }

    public func releaseOwnership(for entry: LibraryEntry, ownerID: UUID, generation: UInt64) throws {
        try withEntryLock(for: entry) {
            var activity = try rawLoad(for: entry)
            guard activity.releaseOwnership(ownerID: ownerID, generation: generation) else { return }
            try rawSave(activity, for: entry)
        }
    }

    /// Atomically records a confirmed exit and releases the matching observation lease.
    @discardableResult
    public func completeSession(
        for entry: LibraryEntry, at date: Date, ownerID: UUID, generation: UInt64
    ) throws -> Bool {
        try withEntryLock(for: entry) {
            var activity = try rawLoad(for: entry)
            guard activity.completeSession(at: date, ownerID: ownerID, generation: generation) else { return false }
            try rawSave(activity, for: entry)
            return true
        }
    }

    // swiftlint:disable:next function_parameter_count
    public func recordSample(
        seconds: TimeInterval,
        at date: Date,
        for entry: LibraryEntry,
        ownerID: UUID,
        generation: UInt64,
        sequence: UInt64
    ) throws -> GameActivityRecordResult {
        guard seconds.isFinite, seconds >= 0 else { return .alreadyApplied }
        return try withEntryLock(for: entry) {
            var activity = try rawLoad(for: entry)

            let result = activity.recordSample(
                seconds: seconds, at: date,
                token: GameActivitySampleToken(ownerID: ownerID, generation: generation, sequence: sequence)
            )
            if case .applied = result {
                try rawSave(activity, for: entry)
            }
            return result
        }
    }

    public func setRating(_ rating: Int?, for entry: LibraryEntry) throws {
        do {
            try GameActivity.validateRating(rating)
        } catch GameActivityValidationError.ratingOutOfRange {
            throw CocoaError(.validationNumberTooLarge)
        }
        try withEntryLock(for: entry) {
            var activity = try rawLoad(for: entry)
            try activity.setRating(rating)
            try rawSave(activity, for: entry)
        }
    }

    public func record(_ seconds: TimeInterval, at date: Date, for entry: LibraryEntry) throws {
        guard seconds.isFinite, seconds >= 0 else { return }
        try withEntryLock(for: entry) {
            var activity = try rawLoad(for: entry)
            activity.record(seconds, at: date)
            try rawSave(activity, for: entry)
        }
    }

    public func copy(from source: LibraryEntry, to target: LibraryEntry) throws {
        let sourceLoc = location(for: source)
        let targetLoc = location(for: target)
        guard sourceLoc != targetLoc else { return }

        let pathA = lockLocation(for: source).path
        let pathB = lockLocation(for: target).path
        let (firstEntry, secondEntry) = pathA < pathB ? (source, target) : (target, source)

        try withEntryLock(for: firstEntry) {
            try withEntryLock(for: secondEntry) {
                guard FileManager.default.fileExists(atPath: sourceLoc.path(percentEncoded: false)) else { return }
                let sourceActivity = try rawLoad(for: source)
                let targetActivity = try rawLoad(for: target)
                let activity = sourceActivity.preservingOwnership(from: targetActivity)
                try rawSave(activity, for: target)
            }
        }
    }

    private func rawLoad(for entry: LibraryEntry) throws -> GameActivity {
        let url = location(for: entry)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return GameActivity() }
        return try JSONDecoder().decode(GameActivity.self, from: Data(contentsOf: url))
    }

    private func rawSave(_ activity: GameActivity, for entry: LibraryEntry) throws {
        try DurableAtomicFile.write(JSONEncoder().encode(activity), to: location(for: entry))
        NotificationCenter.default.post(
            name: Self.didUpdateNotification,
            object: self,
            userInfo: [Self.entryIDKey: entry.id]
        )
    }

    private func digest(for entry: LibraryEntry) -> String {
        LibraryStorageLayout.key(entry.metadataIdentity)
    }

    private func location(for entry: LibraryEntry) -> URL {
        entry.bottleURL.appendingPathComponent("Game Activity", isDirectory: true)
            .appendingPathComponent(digest(for: entry)).appendingPathExtension("json")
    }

    private func lockLocation(for entry: LibraryEntry) -> URL {
        entry.bottleURL.appendingPathComponent("Game Activity", isDirectory: true)
            .appendingPathComponent(digest(for: entry)).appendingPathExtension("lock")
    }
}
