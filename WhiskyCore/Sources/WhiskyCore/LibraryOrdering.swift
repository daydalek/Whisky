//
//  LibraryOrdering.swift
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

public enum LibrarySort: String, CaseIterable, Identifiable, Sendable {
    case recent, name, bottle

    public var id: String {
        rawValue
    }
}

/// Frontends retain their own observation and activity storage wrappers.
public protocol LibrarySortableRow {
    var item: LibraryEntry { get }
    var bottleName: String? { get }
    var lastSessionEndedAt: Date? { get }
}

public enum LibraryOrdering {
    public static func sorted<Row: LibrarySortableRow>(
        _ rows: [Row], by sort: LibrarySort, groupsLaunchers: Bool
    ) -> [Row] {
        rows.sorted { first, second in
            if groupsLaunchers, first.item.isLauncher != second.item.isLauncher {
                return second.item.isLauncher
            }
            switch sort {
            case .recent:
                switch (first.lastSessionEndedAt, second.lastSessionEndedAt) {
                case let (lhs?, rhs?) where lhs != rhs: return lhs > rhs
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            case .bottle:
                let comparison = (first.bottleName ?? "").localizedStandardCompare(second.bottleName ?? "")
                if comparison != .orderedSame {
                    return comparison == .orderedAscending
                }
                let lhs = first.item.bottleURL.absoluteString
                let rhs = second.item.bottleURL.absoluteString
                if lhs != rhs {
                    return lhs < rhs
                }
            case .name: break
            }
            return byName(first, second)
        }
    }

    private static func byName<Row: LibrarySortableRow>(_ first: Row, _ second: Row) -> Bool {
        let comparison = first.item.name.localizedStandardCompare(second.item.name)
        if comparison != .orderedSame {
            return comparison == .orderedAscending
        }
        let lhs = first.item.bottleURL.absoluteString
        let rhs = second.item.bottleURL.absoluteString
        if lhs != rhs {
            return lhs < rhs
        }
        return first.item.id < second.item.id
    }
}
