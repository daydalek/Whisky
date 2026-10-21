//
//  GameActivityObservation.swift
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

/// Observed game processes and confirmed completions, independent of persistence success.
public struct GameActivityObservation: Equatable, Sendable {
    public var runningEntryIDs: Set<String>
    public var endedEntryIDs: Set<String>
    public var revision: UInt64
    public var completedAt: [String: Date]

    public init(
        runningEntryIDs: Set<String> = [], endedEntryIDs: Set<String> = [],
        revision: UInt64 = 0, completedAt: [String: Date] = [:]
    ) {
        self.runningEntryIDs = runningEntryIDs
        self.endedEntryIDs = endedEntryIDs
        self.revision = revision
        self.completedAt = completedAt
    }
}
