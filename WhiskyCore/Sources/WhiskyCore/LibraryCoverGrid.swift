//
//  LibraryCoverGrid.swift
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

/// Compact rows of one- and two-column covers with bounded local reordering.
public struct LibraryCoverGrid: Sendable {
    public let columns: Int
    public let columnWidth: Double
    public let rows: [[Int]]
    public let spans: [Int]
    public let spacing: Double = 12

    public var coverHeight: Double {
        columnWidth * 3 / 2
    }

    public init(width: Double, landscape: [Bool]) {
        self.init(width: width, landscape: landscape, previous: nil)
    }

    private init(width: Double, landscape: [Bool], previous: LibraryCoverGrid?) {
        let available = max(width.isFinite ? width : 1, 1)
        let columnCount = max(1, Int((available + spacing) / (140 + spacing)))
        columns = columnCount
        columnWidth = (available - Double(columnCount - 1) * spacing) / Double(columnCount)
        spans = landscape.map { $0 ? min(2, columnCount) : 1 }
        if let previous, previous.columns == columns, previous.spans == spans {
            rows = previous.rows
        } else {
            rows = Self.pack(spans: spans, columns: columnCount)
        }
    }

    /// Retains one packing while width, colours or unrelated row state changes.
    @MainActor
    public final class Cache {
        private var previous: LibraryCoverGrid?
        public init() {}

        public func layout(width: Double, landscape: [Bool]) -> LibraryCoverGrid {
            let result = LibraryCoverGrid(width: width, landscape: landscape, previous: previous)
            previous = result
            return result
        }
    }

    private struct Choice {
        let positions: [Int]
        let cost: Int
    }

    private struct Capacity: Hashable {
        let used: Int
        let count: Int
    }

    /// Each row includes the oldest pending item. A small knapsack DP then
    /// fills the row with nearby entries, minimizing inversions and adjacent-row
    /// landscape alignment among equally full choices.
    private static func pack(spans: [Int], columns: Int) -> [[Int]] {
        var consumed = [Bool](repeating: false, count: spans.count)
        var head = 0
        var rows: [[Int]] = []
        var previousLandscapeOffsets = Set<Int>()
        let window = min(12, max(columns + 2, 4))
        while head < spans.count {
            var candidates: [Int] = []
            var cursor = head
            while cursor < spans.count, candidates.count < window {
                if !consumed[cursor] {
                    candidates.append(cursor)
                }
                cursor += 1
            }
            let selected = selectRow(
                candidates: candidates,
                spans: spans,
                columns: columns,
                previousLandscapeOffsets: previousLandscapeOffsets
            )
            let row = staggerRow(
                selected,
                spans: spans,
                previousLandscapeOffsets: previousLandscapeOffsets
            )
            rows.append(row)
            previousLandscapeOffsets = landscapeOffsets(in: row, spans: spans)
            for index in row {
                consumed[index] = true
            }
            while head < spans.count, consumed[head] {
                head += 1
            }
        }
        return rows
    }

    private static func selectRow(
        candidates: [Int],
        spans: [Int],
        columns: Int,
        previousLandscapeOffsets: Set<Int>
    ) -> [Int] {
        let firstSpan = spans[candidates[0]]
        let firstPenalty = (firstSpan > 1 && previousLandscapeOffsets.contains(0)) ? 2 : 0
        let first = Capacity(used: firstSpan, count: 1)
        var choices = [first: Choice(positions: [0], cost: firstPenalty)]
        for position in candidates.indices.dropFirst() {
            var updated = choices
            let span = spans[candidates[position]]
            for (capacity, choice) in choices {
                let startColumn = capacity.used
                let used = startColumn + span
                guard used <= columns else { continue }
                let key = Capacity(used: used, count: capacity.count + 1)
                let overlapPenalty = (span > 1 && previousLandscapeOffsets.contains(startColumn)) ? 2 : 0
                let proposal = Choice(
                    positions: choice.positions + [position],
                    cost: choice.cost + (position - capacity.count) + overlapPenalty
                )
                if let existing = updated[key] {
                    if precedes(proposal, existing) {
                        updated[key] = proposal
                    }
                } else {
                    updated[key] = proposal
                }
            }
            choices = updated
        }
        var bestCapacity = first
        var best = choices[first] ?? Choice(positions: [0], cost: firstPenalty)
        for (capacity, choice) in choices {
            if capacity.used > bestCapacity.used
                || (capacity.used == bestCapacity.used && precedes(choice, best)) {
                bestCapacity = capacity
                best = choice
            }
        }
        return best.positions.map { candidates[$0] }
    }

    /// Shifts a wide card within `row[1...]` when it would land on the exact same
    /// column index as a wide card in the preceding row, staggering visual weight.
    private static func staggerRow(
        _ row: [Int],
        spans: [Int],
        previousLandscapeOffsets: Set<Int>
    ) -> [Int] {
        guard row.count > 2, !previousLandscapeOffsets.isEmpty else { return row }
        let currentOffsets = landscapeOffsets(in: row, spans: spans)
        guard !currentOffsets.isDisjoint(with: previousLandscapeOffsets),
              let widePosition = row.indices.dropFirst().first(where: { spans[row[$0]] > 1 })
        else {
            return row
        }
        var bestOrder = row
        var bestClearance = -1
        for target in row.indices.dropFirst() where target != widePosition {
            var candidate = row
            let item = candidate.remove(at: widePosition)
            candidate.insert(item, at: target)
            let offsets = landscapeOffsets(in: candidate, spans: spans)
            guard offsets.isDisjoint(with: previousLandscapeOffsets) else { continue }
            let clearance = offsets.map { offset in
                previousLandscapeOffsets.map { abs(offset - $0) }.min() ?? 0
            }.min() ?? 0
            if clearance > bestClearance {
                bestClearance = clearance
                bestOrder = candidate
            }
        }
        return bestOrder
    }

    private static func landscapeOffsets(in row: [Int], spans: [Int]) -> Set<Int> {
        var offsets = Set<Int>()
        var column = 0
        for index in row {
            let span = spans[index]
            if span > 1 {
                offsets.insert(column)
            }
            column += span
        }
        return offsets
    }

    private static func precedes(_ lhs: Choice, _ rhs: Choice) -> Bool {
        lhs.cost < rhs.cost
            || (lhs.cost == rhs.cost && lhs.positions.lexicographicallyPrecedes(rhs.positions))
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
