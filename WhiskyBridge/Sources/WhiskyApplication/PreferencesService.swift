//
//  PreferencesService.swift
//  WhiskyBridge
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
import WhiskyBridgeProtocol

@MainActor
public final class PreferencesService {
    public static let methods = ["preferences.read", "preferences.set", "preferences.schema"]
    private let defaults: UserDefaults
    private let defaultBottleDirectory: URL
    private static let flags: [String: Bool] = [
        "offlineMode": false, "killOnTerminate": true, "showMenuBarExtra": false,
        "checkWhiskyWineUpdates": true, "libraryRefreshAfterExit": true,
        "libraryDetailBlurredBackground": true, "librarySingleLineTitles": false,
        "libraryCenterWideCoverText": false, "libraryMixedCoverLayout": false, "libraryBlurredCoverFill": true
    ]
    private static let texts: [String: String] = ["preferredTerminal": "terminal", "libraryCoverFillStyle": "blurred"]
    public init(defaults: UserDefaults, defaultBottleDirectory: URL) {
        self.defaults = defaults
        self.defaultBottleDirectory = defaultBottleDirectory
    }

    public func call(_ method: String, params: [String: JSONValue]) throws -> JSONValue {
        if method == "preferences.schema" {
            return .object([
                "booleans": .object(Self.flags.mapValues(JSONValue.bool)),
                "strings": .object(Self.texts.mapValues(JSONValue.string)),
                "paths": .array([.string("defaultBottleLocation")])
            ])
        }
        if method == "preferences.set" {
            let key = try params.text("key")
            if Self.flags[key] != nil {
                try defaults.set(params.flag("value"), forKey: key)
            } else if Self.texts[key] != nil {
                try defaults.set(params.text("value"), forKey: key)
            } else if key == "defaultBottleLocation" {
                try defaults.set(params.path("value"), forKey: key)
            } else {
                throw BridgeFailure("invalid_params", "Unknown application preference: \(key)")
            }
        }
        defaults.synchronize()
        var values = Self.flags.mapValues(JSONValue.bool)
        for key in Self.flags.keys {
            if let flag = defaults.object(forKey: key) as? Bool {
                values[key] = .bool(flag)
            }
        }
        for (key, fallback) in Self.texts {
            values[key] = .string(defaults.string(forKey: key) ?? fallback)
        }
        values["defaultBottleLocation"] =
            .string((defaults.url(forKey: "defaultBottleLocation") ?? defaultBottleDirectory).path)
        return .object(values)
    }
}
