//
//  LauncherSettings.swift
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

/// Per-bottle launcher preferences: which storefront clients open on their own.
///
/// Membership is keyed by ``LibraryEntry/metadataIdentity`` so a flag survives
/// rescans and stays attached when a bottle moves — a `program:` identity is
/// relative to the bottle while an `id` carries the container's full path.
public struct LauncherSettings: Codable, Sendable {
    /// Identities the user wants Whisky to launch automatically on startup.
    public var autoStart: Set<String> = []

    public init() {}

    public static func load(bottleURL: URL) throws -> Self {
        let url = location(bottleURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    public func save(bottleURL: URL) throws {
        try JSONEncoder().encode(self).write(to: Self.location(bottleURL), options: .atomic)
    }

    public mutating func setAutoStart(_ enabled: Bool, for entry: LibraryEntry) {
        if enabled {
            autoStart.insert(entry.metadataIdentity)
        } else {
            autoStart.remove(entry.metadataIdentity)
        }
    }

    private static func location(_ bottle: URL) -> URL {
        bottle.appendingPathComponent("Launcher Settings.json")
    }
}
