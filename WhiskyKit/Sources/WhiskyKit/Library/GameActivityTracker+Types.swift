//
//  GameActivityTracker+Types.swift
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

/// Small bookkeeping values private to the tracker's polling machinery.
extension GameActivityTracker {
    /// A batch of running-state samples awaiting persistence.
    struct SampleBatch {
        let targets: [LibraryEntry]
        let running: Set<String>
        let date: Date
    }

    /// Identifies a game within a bottle for clock and generation bookkeeping.
    struct TrackingKey: Hashable {
        let bottle: URL
        let identity: String
    }

    /// A user-selected executable name awaiting observation.
    struct Selection {
        let identity: String
        let date: Date
        var observed = false
    }
}
