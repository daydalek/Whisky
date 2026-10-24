//
//  WorkspaceEdits.swift
//  WhiskyCrossUI
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
import WhiskyApplication
import WhiskyCore
#if os(macOS)
import WhiskyKit
#endif

actor WorkspaceEdits {
    func setRating(_ rating: Int?, for entry: LibraryEntry) throws {
        #if os(macOS)
        try GameActivityStore.shared.setRating(rating, for: entry)
        #else
        _ = try ApplicationWorkspace().setRating(rating, entry: entry)
        #endif
    }

    func setHidden(_ hidden: Bool, for entry: LibraryEntry) throws {
        let lock = entry.bottleURL.appendingPathComponent("Library Visibility.json.lock")
        try WorkspaceFileLock().withExclusiveLock(at: lock) {
            var visibility = try LibraryVisibility.load(bottleURL: entry.bottleURL)
            visibility.setHidden(hidden, for: entry)
            try visibility.save(bottleURL: entry.bottleURL)
        }
    }
}
