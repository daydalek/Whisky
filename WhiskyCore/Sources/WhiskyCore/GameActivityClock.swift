//
//  GameActivityClock.swift
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
