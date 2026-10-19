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

import CryptoKit
import Darwin
import Foundation

public struct GameActivityOwner: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case gui
        case worker
        case cli
    }

    public var source: Source
    public var ownerID: UUID
    public var hostPID: pid_t
    public var hostProcessBirth: UInt64
    public var generation: UInt64

    public init(
        source: Source,
        ownerID: UUID = UUID(),
        hostPID: pid_t = getpid(),
        hostProcessBirth: UInt64 = GameActivityStore.currentProcessBirth(),
        generation: UInt64 = 1
    ) {
        self.source = source
        self.ownerID = ownerID
        self.hostPID = hostPID
        self.hostProcessBirth = hostProcessBirth
        self.generation = generation
    }
}

public struct GameActivitySampleToken: Codable, Equatable, Sendable {
    public var ownerID: UUID
    public var generation: UInt64
    public var sequence: UInt64

    public init(ownerID: UUID, generation: UInt64, sequence: UInt64) {
        self.ownerID = ownerID
        self.generation = generation
        self.sequence = sequence
    }
}

public enum GameActivityRecordResult: Sendable, Equatable {
    case applied(playTime: TimeInterval)
    case alreadyApplied
    case ownershipChanged(currentOwner: GameActivityOwner?)
}

public struct GameActivity: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var ownershipGeneration: UInt64 = 0
    public var owner: GameActivityOwner?
    public var lastAppliedSample: GameActivitySampleToken?
    public var playTime: TimeInterval = 0
    public var rating: Int?
    public var lastPlayed: Date?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case schemaVersion, ownershipGeneration, owner, lastAppliedSample, playTime, rating, lastPlayed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        owner = try container.decodeIfPresent(GameActivityOwner.self, forKey: .owner)
        lastAppliedSample = try container.decodeIfPresent(GameActivitySampleToken.self, forKey: .lastAppliedSample)
        ownershipGeneration = try container.decodeIfPresent(UInt64.self, forKey: .ownershipGeneration)
            ?? max(owner?.generation ?? 0, lastAppliedSample?.generation ?? 0)
        playTime = try container.decodeIfPresent(TimeInterval.self, forKey: .playTime) ?? 0
        rating = try container.decodeIfPresent(Int.self, forKey: .rating)
        lastPlayed = try container.decodeIfPresent(Date.self, forKey: .lastPlayed)
    }
}

/// Serializes read-modify-write operations for ratings and process samples across processes.
public final class GameActivityStore: Sendable {
    public static let shared = GameActivityStore()
    public static let didUpdateNotification = Notification.Name("com.franke.Whisky.gameActivityStoreDidUpdate")
    public static let entryIDKey = "entryID"

    public init() {}

    public enum OwnershipError: Error, Sendable {
        case heldByLiveOwner(GameActivityOwner)
    }

    /// File locks and disk I/O execute outside the caller's actor.
    public func perform<T: Sendable>(_ operation: @escaping @Sendable (GameActivityStore) throws -> T) async throws
        -> T {
        try await Task.detached(priority: .utility) { try operation(self) }.value
    }

    public static func currentProcessBirth() -> UInt64 {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        if size == MemoryLayout<proc_bsdinfo>.size {
            return UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
        }
        return 0
    }

    public static func isProcessAlive(pid: pid_t, birth: UInt64? = nil) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) != 0 {
            return errno == EPERM
        }
        guard let birth, birth > 0 else { return true }
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard size == MemoryLayout<proc_bsdinfo>.size else { return false }
        let actualBirth = UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
        return actualBirth == birth
    }

    private func withEntryLock<T>(for entry: LibraryEntry, block: () throws -> T) throws -> T {
        let lockURL = lockLocation(for: entry)
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(lockURL.path(percentEncoded: false), O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        var lockResult: Int32 = -1
        repeat {
            lockResult = flock(descriptor, LOCK_EX)
        } while lockResult != 0 && errno == EINTR
        guard lockResult == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try block()
    }

    public func load(for entry: LibraryEntry) throws -> GameActivity {
        // Atomic replacement makes a read observe one complete JSON snapshot.
        try rawLoad(for: entry)
    }

    public func acquireOwnership(
        for entry: LibraryEntry,
        source: GameActivityOwner.Source,
        ownerID: UUID = UUID(),
        hostPID: pid_t = getpid(),
        hostProcessBirth: UInt64 = currentProcessBirth()
    ) throws -> GameActivityOwner {
        try withEntryLock(for: entry) {
            var activity = try rawLoad(for: entry)
            if let current = activity.owner {
                if current.ownerID == ownerID, current.hostPID == hostPID,
                   current.hostProcessBirth == hostProcessBirth {
                    return current
                }
                let alive = Self.isProcessAlive(pid: current.hostPID, birth: current.hostProcessBirth)
                // A worker may take over GUI observation; a live worker keeps its lease.
                if alive, source != .worker || current.source == .worker {
                    throw OwnershipError.heldByLiveOwner(current)
                }
            }
            let newGen = activity.ownershipGeneration + 1
            activity.ownershipGeneration = newGen

            let newOwner = GameActivityOwner(
                source: source,
                ownerID: ownerID,
                hostPID: hostPID,
                hostProcessBirth: hostProcessBirth,
                generation: newGen
            )
            activity.owner = newOwner
            try rawSave(activity, for: entry)
            return newOwner
        }
    }

    public func releaseOwnership(for entry: LibraryEntry, ownerID: UUID, generation: UInt64) throws {
        try withEntryLock(for: entry) {
            var activity = try rawLoad(for: entry)
            guard activity.owner?.ownerID == ownerID, activity.owner?.generation == generation else { return }
            activity.owner = nil
            try rawSave(activity, for: entry)
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

            guard let currentOwner = activity.owner,
                  currentOwner.ownerID == ownerID, currentOwner.generation == generation
            else {
                return .ownershipChanged(currentOwner: activity.owner)
            }

            if let last = activity.lastAppliedSample,
               last.ownerID == ownerID,
               last.generation == generation,
               last.sequence >= sequence {
                return .alreadyApplied
            }

            activity.playTime += seconds
            activity.lastPlayed = max(activity.lastPlayed ?? date, date)
            activity.lastAppliedSample = GameActivitySampleToken(
                ownerID: ownerID,
                generation: generation,
                sequence: sequence
            )
            try rawSave(activity, for: entry)
            return .applied(playTime: activity.playTime)
        }
    }

    public func setRating(_ rating: Int?, for entry: LibraryEntry) throws {
        if let rating, !(1 ... 10).contains(rating) {
            throw CocoaError(.validationNumberTooLarge)
        }
        try withEntryLock(for: entry) {
            var activity = try rawLoad(for: entry)
            activity.rating = rating
            try rawSave(activity, for: entry)
        }
    }

    public func record(_ seconds: TimeInterval, at date: Date, for entry: LibraryEntry) throws {
        guard seconds.isFinite, seconds >= 0 else { return }
        try withEntryLock(for: entry) {
            var activity = try rawLoad(for: entry)
            activity.playTime += seconds
            activity.lastPlayed = max(activity.lastPlayed ?? date, date)
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
                var activity = try rawLoad(for: source)
                let targetActivity = try rawLoad(for: target)
                activity.owner = targetActivity.owner
                activity.ownershipGeneration = targetActivity.ownershipGeneration
                activity.lastAppliedSample = targetActivity.lastAppliedSample
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
        SHA256.hash(data: Data(entry.metadataIdentity.utf8))
            .map { String(format: "%02x", $0) }.joined()
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

/// Counts intervals bracketed by successful running-process observations.
/// Long gaps (sleep, stalled probes) begin a fresh interval.
public struct GameActivityClock: Sendable {
    private var previous: (uptime: TimeInterval, running: Set<String>)?

    public init() {}

    /// Ambiguous image names require an explicit library launch selection.
    public static func match(
        executables: [String: Set<String>], runningNames: Set<String>, preferred: [String: String] = [:]
    ) -> Set<String> {
        var result: Set<String> = []
        for name in runningNames {
            let candidates = executables.filter { $0.value.contains(name) }.map(\.key)
            if let selected = preferred[name], candidates.contains(selected) {
                result.insert(selected)
            } else if candidates.count == 1, let identity = candidates.first {
                result.insert(identity)
            }
        }
        return result
    }

    public mutating func reset() {
        previous = nil
    }

    public mutating func sample(
        running: Set<String>,
        at date: Date,
        uptime: TimeInterval? = nil
    ) -> [String: TimeInterval] {
        let current = uptime ?? date.timeIntervalSinceReferenceDate
        defer { previous = (current, running) }
        guard let previous else {
            return Dictionary(uniqueKeysWithValues: running.map { ($0, 0) })
        }
        let elapsed = current - previous.uptime
        let validInterval = elapsed >= 0 && elapsed <= 30
        return Dictionary(uniqueKeysWithValues: running.map { identity in
            (identity, validInterval && previous.running.contains(identity) ? elapsed : 0)
        })
    }
}
