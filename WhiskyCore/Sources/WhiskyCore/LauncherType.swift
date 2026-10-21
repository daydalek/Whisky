//
//  LauncherType.swift
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

public enum LauncherType: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Valve Steam platform
    case steam = "Steam"
    /// Rockstar Games Launcher
    case rockstar = "Rockstar Games Launcher"
    /// Electronic Arts App (formerly Origin)
    case eaApp = "EA App"
    /// Epic Games Store launcher
    case epicGames = "Epic Games Store"
    /// Ubisoft Connect (formerly Uplay)
    case ubisoft = "Ubisoft Connect"
    /// Blizzard Battle.net launcher
    case battleNet = "Battle.net"
    /// Paradox Launcher
    case paradox = "Paradox Launcher"

    public var id: String {
        rawValue
    }

    /// Display name for the launcher.
    public var displayName: String {
        switch self {
        case .steam:
            "Steam"
        case .rockstar:
            "Rockstar Games Launcher"
        case .eaApp:
            "EA App"
        case .epicGames:
            "Epic Games Store"
        case .ubisoft:
            "Ubisoft Connect"
        case .battleNet:
            "Battle.net"
        case .paradox:
            "Paradox Launcher"
        }
    }
}

public extension LauncherType {
    /// Whether this launcher is known to use the clipboard for multiplayer features.
    var usesClipboard: Bool {
        switch self {
        case .steam, .epicGames, .battleNet:
            true
        default:
            false
        }
    }
}
