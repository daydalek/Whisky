//
//  SteamLibrary.swift
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
import WhiskyCore

public typealias SteamGame = WhiskyCore.SteamGame
public typealias SteamLibrary = WhiskyCore.SteamLibrary

extension SteamLibrary {
    /// Discovers library roots for a bottle.
    public static func libraryRoots(in bottle: Bottle) -> [URL] {
        libraryRoots(bottleURL: bottle.url)
    }

    /// Picks the overrides a library launch should carry from the game's
    /// executables' persisted settings: the shallowest one that has any, ties
    /// broken by name so the pick does not move between scans.
    ///
    /// Steam games surface as ordinary Programs, so a user can tune one in the
    /// Programs tab, and those settings have to survive the Play button.
    public static func preferredOverrides(among candidates: [ProgramOverrideCandidate]) -> ProgramOverrides? {
        candidates
            .filter { !$0.overrides.isEmpty }
            .min { lhs, rhs in
                let left = lhs.url.pathComponents.count
                let right = rhs.url.pathComponents.count
                guard left == right else { return left < right }
                return lhs.url.lastPathComponent
                    .localizedCaseInsensitiveCompare(rhs.url.lastPathComponent) == .orderedAscending
            }?
            .overrides
    }
}

/// One executable's persisted overrides, for ``SteamLibrary/preferredOverrides(among:)``.
public struct ProgramOverrideCandidate: Equatable, Sendable {
    public let url: URL
    public let overrides: ProgramOverrides

    public init(url: URL, overrides: ProgramOverrides) {
        self.url = url
        self.overrides = overrides
    }
}
