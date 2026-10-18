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
import Foundation

public struct GameActivity: Codable, Equatable, Sendable {
    public fileprivate(set) var playTime: TimeInterval = 0
    public fileprivate(set) var rating: Int?
    public fileprivate(set) var lastPlayed: Date?

    public init() {}
}

/// Serializes read-modify-write operations for ratings and process samples.
/// Personal records live outside the replaceable metadata cache.
@MainActor
public final class GameActivityStore {
    public static let shared = GameActivityStore()

    public init() {}

    public func load(for entry: LibraryEntry) throws -> GameActivity {
        let url = location(for: entry)
        guard FileManager.default.fileExists(atPath: url.path) else { return GameActivity() }
        return try JSONDecoder().decode(GameActivity.self, from: Data(contentsOf: url))
    }

    public func setRating(_ rating: Int?, for entry: LibraryEntry) throws {
        if let rating, !(1 ... 10).contains(rating) {
            throw CocoaError(.validationNumberTooLarge)
        }
        var activity = try load(for: entry)
        activity.rating = rating
        try save(activity, for: entry)
    }

    public func record(_ seconds: TimeInterval, at date: Date, for entry: LibraryEntry) throws {
        guard seconds.isFinite, seconds >= 0 else { return }
        var activity = try load(for: entry)
        activity.playTime += seconds
        activity.lastPlayed = max(activity.lastPlayed ?? date, date)
        try save(activity, for: entry)
    }

    public func copy(from source: LibraryEntry, to target: LibraryEntry) throws {
        guard FileManager.default.fileExists(atPath: location(for: source).path) else { return }
        try save(load(for: source), for: target)
    }

    private func save(_ activity: GameActivity, for entry: LibraryEntry) throws {
        let url = location(for: entry)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(activity).write(to: url, options: .atomic)
    }

    private func location(for entry: LibraryEntry) -> URL {
        let digest = SHA256.hash(data: Data(entry.metadataIdentity.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return entry.bottleURL.appendingPathComponent("Game Activity", isDirectory: true)
            .appendingPathComponent(digest).appendingPathExtension("json")
    }
}

/// Counts intervals bracketed by successful running-process observations.
/// Long gaps (sleep, stalled probes) begin a fresh interval.
public struct GameActivityClock: Sendable {
    private var previous: (date: Date, running: Set<String>)?

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

    public mutating func sample(running: Set<String>, at date: Date) -> [String: TimeInterval] {
        defer { previous = (date, running) }
        guard let previous else {
            return Dictionary(uniqueKeysWithValues: running.map { ($0, 0) })
        }
        let elapsed = date.timeIntervalSince(previous.date)
        let validInterval = elapsed >= 0 && elapsed <= 30
        return Dictionary(uniqueKeysWithValues: running.map { identity in
            (identity, validInterval && previous.running.contains(identity) ? elapsed : 0)
        })
    }
}
