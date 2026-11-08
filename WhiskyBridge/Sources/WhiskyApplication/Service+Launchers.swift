//
//  Service+Launchers.swift
//  WhiskyApplication
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
import WhiskyCore

// MARK: - Launcher preference methods

extension ApplicationService {
    func launchersCall(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
        let container = try workspace.resolve(params)
        switch method {
        case "launchers.read":
            return try Self.encodeLaunchers(LauncherSettings.load(bottleURL: container))
        case "launchers.setAutoStart":
            // Resolving through the workspace keeps the flag keyed to a real
            // entry's `metadataIdentity`, not a client-guessed string.
            let entry = try await workspace.entry(params)
            let enabled = try params.flag("enabled")
            let lockURL = container.appendingPathComponent("Launcher Settings.json.lock")
            let settings = try HostFileLock().withExclusiveLock(at: lockURL) {
                var settings = try LauncherSettings.load(bottleURL: container)
                settings.setAutoStart(enabled, for: entry)
                try settings.save(bottleURL: container)
                return settings
            }
            return Self.encodeLaunchers(settings)
        default:
            return try await nativeCall(method, params: params)
        }
    }

    private static func encodeLaunchers(_ settings: LauncherSettings) -> JSONValue {
        .object(["autoStart": .array(settings.autoStart.sorted().map(JSONValue.string))])
    }
}
