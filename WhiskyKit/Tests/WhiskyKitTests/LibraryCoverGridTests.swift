//
//  LibraryCoverGridTests.swift
//  WhiskyKitTests
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

@Suite("Mixed cover grid")
struct LibraryCoverGridTests {
    @Test func coversEveryEntryWithinBoundsWhileResizing() {
        let landscape = [false, true, false, true, true, false, false, true]
        for width in [1.0, 139, 300, 464, 900, 1_500] {
            let layout = LibraryCoverGrid(width: width, landscape: landscape)
            #expect(layout.rows.flatMap { $0 }.sorted() == Array(landscape.indices))
            if layout.columns == 1 {
                #expect(layout.rows.flatMap { $0 } == Array(landscape.indices))
            }
            var remaining = Set(landscape.indices)
            #expect(layout.columnWidth > 0)
            for row in layout.rows {
                #expect(row.first == remaining.min())
                remaining.subtract(row)
                #expect(row.reduce(0) { $0 + layout.spans[$1] } <= layout.columns)
                let used = row.reduce(0.0) { $0 + layout.width(for: $1) }
                    + Double(row.count - 1) * layout.spacing
                #expect(used <= width + 0.0001)
                for index in row {
                    #expect(layout.spans[index] == (landscape[index] ? min(2, layout.columns) : 1))
                }
            }
        }
    }

    @Test func wideCoversIncludeTheGutterAndShareArtworkHeight() {
        let layout = LibraryCoverGrid(width: 464, landscape: [true, false, true])
        #expect(layout.columns == 3)
        #expect(layout.rows == [[0, 1], [2]])
        #expect(layout.width(for: 0) == 2 * layout.columnWidth + 22)
        #expect(layout.coverHeight == layout.columnWidth * 4 / 3)
        let portraitAspect = layout.columnWidth / layout.coverHeight
        let landscapeAspect = layout.width(for: 0) / layout.coverHeight
        #expect(LibraryCoverGrid.shouldStretch(imageAspect: 2.0 / 3, targetAspect: portraitAspect))
        #expect(LibraryCoverGrid.shouldStretch(imageAspect: 16.0 / 9, targetAspect: landscapeAspect))
        #expect(LibraryCoverGrid(width: 300, landscape: []).rows.isEmpty)
    }

    @Test func fillsScreenshotGapWithNearbyPortrait() {
        let landscape = [
            false,
            false,
            false,
            false,
            true,
            false,
            false,
            false,
            false,
            false,
            false,
            false,
            false,
            false,
            true,
            false,
            false,
            false,
            false,
            false,
            false
        ]
        let layout = LibraryCoverGrid(width: 1_274, landscape: landscape)
        #expect(layout.columns == 8)
        #expect(layout.rows[0] == Array(0 ... 6))
        #expect(layout.rows[1] == [7, 8, 9, 10, 11, 12, 13, 15])
        #expect(layout.rows[2].first == 14)
        let narrow = LibraryCoverGrid(width: 302, landscape: [false, true, true, false])
        #expect(narrow.rows == [[0, 3], [1], [2]])
    }

    @Test func prefersSortedRowsAndBoundsLookahead() {
        let sorted = LibraryCoverGrid(width: 464, landscape: [false, true, true, false])
        #expect(sorted.rows == [[0, 1], [2, 3]])
        let distant = [false] + [Bool](repeating: true, count: 10) + [false]
        let bounded = LibraryCoverGrid(width: 302, landscape: distant)
        #expect(bounded.rows[0] == [0])
        #expect(bounded.rows.flatMap { $0 } == Array(distant.indices))
    }

    @Test func dynamicProgrammingMatchesExhaustiveRowScores() throws {
        for pattern in 0 ..< 128 {
            let landscape = (0 ..< 7).map { pattern & (1 << $0) != 0 }
            for columns in 1 ... 4 {
                let layout = LibraryCoverGrid(width: Double(columns * 162 - 22), landscape: landscape)
                var pending = Array(landscape.indices)
                for row in layout.rows {
                    let window = Array(pending.prefix(min(12, max(columns + 2, 4))))
                    var bestUsed = 0
                    var bestInversions = Int.max
                    for mask in 1 ..< (1 << window.count) where mask & 1 == 1 {
                        let positions = window.indices.filter { mask & (1 << $0) != 0 }
                        let used = positions.reduce(0) { $0 + layout.spans[window[$1]] }
                        guard used <= columns else { continue }
                        let inversions = positions.enumerated().reduce(0) { $0 + $1.element - $1.offset }
                        if used > bestUsed || (used == bestUsed && inversions < bestInversions) {
                            bestUsed = used
                            bestInversions = inversions
                        }
                    }
                    let positions = try row.map { try #require(window.firstIndex(of: $0)) }
                    let used = row.reduce(0) { $0 + layout.spans[$1] }
                    let inversions = positions.enumerated().reduce(0) { $0 + $1.element - $1.offset }
                    #expect(used == bestUsed)
                    #expect(inversions == bestInversions)
                    pending.removeAll { row.contains($0) }
                }
            }
        }
    }

    @Test func stretchingHonoursSymmetricToleranceAndInvalidDimensions() {
        #expect(LibraryCoverGrid.shouldStretch(imageAspect: 0.7, targetAspect: 2.0 / 3))
        #expect(LibraryCoverGrid.shouldStretch(imageAspect: 1.5, targetAspect: 1.4))
        #expect(LibraryCoverGrid.shouldStretch(imageAspect: 1.2, targetAspect: 1))
        #expect(!LibraryCoverGrid.shouldStretch(imageAspect: 16.0 / 9, targetAspect: 2.0 / 3))
        #expect(!LibraryCoverGrid.shouldStretch(imageAspect: 1.21, targetAspect: 1))
        #expect(!LibraryCoverGrid.shouldStretch(imageAspect: 1, targetAspect: 1.21))
        #expect(!LibraryCoverGrid.shouldStretch(imageAspect: 0, targetAspect: 1))
        #expect(!LibraryCoverGrid.shouldStretch(imageAspect: .infinity, targetAspect: 1))
        #expect(!LibraryCoverGrid.shouldStretch(imageAspect: 1, targetAspect: .nan))
    }
}
