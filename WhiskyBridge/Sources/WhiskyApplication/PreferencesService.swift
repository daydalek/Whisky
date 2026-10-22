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
    private let defaults: UserDefaults?
    private let fileURL: URL?
    private let defaultBottleDirectory: URL
    /// Every boolean `@AppStorage` the SwiftUI app reads. `libraryMixedCoverLayout`
    /// defaults to `true` here because that is the value `LibraryView` renders
    /// with when the key is absent; the settings form must show the same state.
    private static let flags: [String: Bool] = [
        "offlineMode": false, "killOnTerminate": true, "showMenuBarExtra": false,
        "checkWhiskyWineUpdates": true, "libraryRefreshAfterExit": true,
        "libraryDetailBlurredBackground": true, "librarySingleLineTitles": false,
        "libraryCenterWideCoverText": false, "libraryMixedCoverLayout": true, "libraryBlurredCoverFill": true
    ]
    /// String-backed preferences. Values mirror the Swift enums (`LibraryDisplayMode`,
    /// `LibrarySort`, `LibraryDetailLayoutStyle`) and `TerminalApp` raw values.
    private static let texts: [String: String] = [
        "preferredTerminal": "terminal", "libraryCoverFillStyle": "blurred",
        "libraryDisplayMode": "covers", "librarySort": "recent",
        "libraryDetailLayoutStyle": "hero",
        "libraryMetadataEnabledSources": "bangumi,vndb,steam,ymgal",
        "telemetryConsent": "undecided"
    ]
    private static let pathKeys = ["defaultBottleLocation"]
    public init(defaults: UserDefaults, defaultBottleDirectory: URL) {
        self.defaults = defaults
        self.fileURL = nil
        self.defaultBottleDirectory = defaultBottleDirectory
    }

    /// Linux preferences use an explicit XDG file and a process-shared lock.
    public init(fileURL: URL, defaultBottleDirectory: URL) {
        self.defaults = nil
        self.fileURL = fileURL
        self.defaultBottleDirectory = defaultBottleDirectory
    }

    public func call(_ method: String, params: [String: JSONValue]) throws -> JSONValue {
        if method == "preferences.schema" {
            return .object([
                "booleans": .object(Self.flags.mapValues(JSONValue.bool)),
                "strings": .object(Self.texts.mapValues(JSONValue.string)),
                "paths": .array(Self.pathKeys.map(JSONValue.string))
            ])
        }
        guard method == "preferences.read" || method == "preferences.set" else {
            throw BridgeFailure("method_unavailable", "Unknown preference method")
        }
        if let fileURL {
            return try fileCall(method, params: params, at: fileURL)
        }
        guard let defaults else { throw BridgeFailure("host_failed", "Preference storage is unavailable") }
        return try defaultsCall(method, params: params, defaults: defaults)
    }

    private func defaultsCall(
        _ method: String, params: [String: JSONValue], defaults: UserDefaults
    ) throws -> JSONValue {
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
        let storedLocation = defaults.url(forKey: "defaultBottleLocation")?.path
            ?? defaults.string(forKey: "defaultBottleLocation")
        values["defaultBottleLocation"] = .string(storedLocation ?? defaultBottleDirectory.path)
        return .object(values)
    }

    private func fileCall(_ method: String, params: [String: JSONValue], at url: URL) throws -> JSONValue {
        try HostFileLock().withExclusiveLock(at: url.appendingPathExtension("lock")) {
            var stored: [String: Any] = [:]
            if FileManager.default.fileExists(atPath: url.path) {
                guard let dictionary = try PropertyListSerialization.propertyList(
                    from: Data(contentsOf: url), options: [], format: nil
                ) as? [String: Any] else {
                    throw BridgeFailure("invalid_settings", "Application preferences are unreadable")
                }
                stored = dictionary
            }
            if method == "preferences.set" {
                let key = try params.text("key")
                if Self.flags[key] != nil {
                    stored[key] = try params.flag("value")
                } else if Self.texts[key] != nil {
                    stored[key] = try params.text("value")
                } else if key == "defaultBottleLocation" {
                    stored[key] = try params.path("value").path
                } else {
                    throw BridgeFailure("invalid_params", "Unknown application preference: \(key)")
                }
                let data = try PropertyListSerialization.data(fromPropertyList: stored, format: .binary, options: 0)
                try data.write(to: url, options: .atomic)
            }
            var values = Self.flags.mapValues(JSONValue.bool)
            for key in Self.flags.keys {
                if let value = stored[key] as? Bool { values[key] = .bool(value) }
            }
            for (key, fallback) in Self.texts {
                values[key] = .string(stored[key] as? String ?? fallback)
            }
            values["defaultBottleLocation"] = .string(
                stored["defaultBottleLocation"] as? String ?? defaultBottleDirectory.path
            )
            return .object(values)
        }
    }
}
