//
//  LibraryCoverGrid.swift
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

/// Compact rows of one- and two-column covers with bounded local reordering.
public struct LibraryCoverGrid: Sendable {
    public let columns: Int
    public let columnWidth: Double
    public let rows: [[Int]]
    public let spans: [Int]
    public let spacing: Double = 22

    public var coverHeight: Double { columnWidth * 4 / 3 }

    public init(width: Double, landscape: [Bool]) {
        let available = max(width.isFinite ? width : 1, 1)
        let columnCount = max(1, Int((available + 22) / 162))
        columns = columnCount
        columnWidth = (available - Double(columnCount - 1) * 22) / Double(columnCount)
        spans = landscape.map { $0 ? min(2, columnCount) : 1 }
        rows = Self.pack(spans: spans, columns: columnCount)
    }

    private struct Choice {
        let positions: [Int]
        let inversions: Int
    }

    private struct Capacity: Hashable {
        let used: Int
        let count: Int
    }

    /// Each row includes the oldest pending item. A small knapsack DP then
    /// fills the row with nearby entries, minimizing inversions among equally
    /// full choices. A full sorted prefix has zero inversions and wins ties.
    private static func pack(spans: [Int], columns: Int) -> [[Int]] {
        var consumed = [Bool](repeating: false, count: spans.count)
        var head = 0
        var rows: [[Int]] = []
        let window = min(12, max(columns + 2, 4))
        while head < spans.count {
            var candidates: [Int] = []
            var cursor = head
            while cursor < spans.count, candidates.count < window {
                if !consumed[cursor] { candidates.append(cursor) }
                cursor += 1
            }
            let row = selectRow(candidates: candidates, spans: spans, columns: columns)
            rows.append(row)
            for index in row {
                consumed[index] = true
            }
            while head < spans.count, consumed[head] {
                head += 1
            }
        }
        return rows
    }

    private static func selectRow(candidates: [Int], spans: [Int], columns: Int) -> [Int] {
        let first = Capacity(used: spans[candidates[0]], count: 1)
        var choices = [first: Choice(positions: [0], inversions: 0)]
        for position in candidates.indices.dropFirst() {
            var updated = choices
            for (capacity, choice) in choices {
                let used = capacity.used + spans[candidates[position]]
                guard used <= columns else { continue }
                let key = Capacity(used: used, count: capacity.count + 1)
                let proposal = Choice(
                    positions: choice.positions + [position],
                    inversions: choice.inversions + position - capacity.count
                )
                if let existing = updated[key] {
                    if precedes(proposal, existing) { updated[key] = proposal }
                } else {
                    updated[key] = proposal
                }
            }
            choices = updated
        }
        var bestCapacity = first
        var best = choices[first] ?? Choice(positions: [0], inversions: 0)
        for (capacity, choice) in choices {
            if capacity.used > bestCapacity.used
                || (capacity.used == bestCapacity.used && precedes(choice, best)) {
                bestCapacity = capacity
                best = choice
            }
        }
        return best.positions.map { candidates[$0] }
    }

    private static func precedes(_ lhs: Choice, _ rhs: Choice) -> Bool {
        lhs.inversions < rhs.inversions
            || (lhs.inversions == rhs.inversions && lhs.positions.lexicographicallyPrecedes(rhs.positions))
    }

    public func width(for index: Int) -> Double {
        let span = spans[index]
        return Double(span) * columnWidth + Double(span - 1) * spacing
    }

    /// A symmetric tolerance bounds stretching in either direction to 20 percent.
    public static func shouldStretch(imageAspect: Double, targetAspect: Double) -> Bool {
        guard imageAspect.isFinite, targetAspect.isFinite, imageAspect > 0, targetAspect > 0 else { return false }
        return max(imageAspect, targetAspect) / min(imageAspect, targetAspect) <= 1.2
    }
}
