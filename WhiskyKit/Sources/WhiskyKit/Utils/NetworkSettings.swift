//
//  NetworkSettings.swift
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

/// Persistent controls for Whisky's own network activity. Wine programs keep
/// their own network settings.
public enum NetworkSettings {
    public static let offlineModeKey = "offlineMode"
    public static let wineUpdatesKey = "checkWhiskyWineUpdates"

    public static var isOffline: Bool {
        WhiskyPreferences.userDefaults.bool(forKey: offlineModeKey)
    }

    public static func shouldCheckWineUpdates(defaults: UserDefaults = WhiskyPreferences.userDefaults) -> Bool {
        !defaults.bool(forKey: offlineModeKey)
            && (defaults.object(forKey: wineUpdatesKey) as? Bool ?? true)
    }

    public static func requireNetwork() throws {
        if isOffline {
            throw URLError(.notConnectedToInternet)
        }
    }
}
