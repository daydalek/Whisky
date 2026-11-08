//
//  WineDisplayRegistry.swift
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
import os.log

private let logger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "WineDisplayRegistry")

/// Marker for display-mode registry sync state so launches only spawn a Wine
/// process when the setting actually changed.
struct DisplayModeRegistryState: Codable, Equatable {
    /// Whether `HKCU\Software\Wine\X11 Driver\EmulateModeset` is written.
    var emulateModeset: Bool

    /// Wine's own default: real mode changes, no `EmulateModeset` value.
    static let factoryDefault = DisplayModeRegistryState(emulateModeset: false)

    static func markerURL(in bottleURL: URL) -> URL {
        bottleURL.appending(path: ".display-registry-state.plist")
    }

    static func load(from bottleURL: URL) -> DisplayModeRegistryState? {
        guard let data = try? Data(contentsOf: markerURL(in: bottleURL)) else { return nil }
        return try? PropertyListDecoder().decode(DisplayModeRegistryState.self, from: data)
    }

    func save(to bottleURL: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(self).write(to: Self.markerURL(in: bottleURL), options: .atomic)
    }
}

public extension Wine {
    /// Synchronizes the emulated display mode setting before the next process starts.
    @MainActor
    static func syncDisplayModeRegistry(bottle: Bottle, emulateModeset: Bool) async {
        do {
            try await syncDisplayModeRegistry(
                bottle: bottle, emulateModeset: emulateModeset,
                importer: { try await importRegistry(document: $0, bottle: $1) }
            )
        } catch {
            logger.error("Failed to sync display mode registry: \(error.localizedDescription)")
        }
    }
}

extension Wine {
    /// Writes or removes `EmulateModeset` under `HKCU\Software\Wine\X11 Driver`.
    ///
    /// Wine's display drivers share that section even on macOS. `Y` makes a
    /// mode change only resize Wine's emulated monitor — low-resolution games
    /// get aspect-preserving scaling with centered output instead of a
    /// `DISP_CHANGE_BADMODE` failure that strands their window at the origin.
    /// Disabling deletes the value so the prefix returns to real mode changes.
    ///
    /// The key lives in `user.reg`: prefix recreation drops it, which is why
    /// the launch path re-applies the configured value rather than relying on
    /// a one-off `reg add`. The marker records what the last launch wrote so
    /// unchanged launches skip the Wine round-trip; a missing marker on a
    /// disabled setting is stamped without booting wineserver.
    @MainActor
    static func syncDisplayModeRegistry(
        bottle: Bottle, emulateModeset: Bool, importer: RegistryImporter
    ) async throws {
        let desired = DisplayModeRegistryState(emulateModeset: emulateModeset)
        let applied = DisplayModeRegistryState.load(from: bottle.url)
        guard desired != applied else { return }
        if applied == nil, desired == .factoryDefault {
            try desired.save(to: bottle.url)
            return
        }

        var lines = [
            "Windows Registry Editor Version 5.00", "",
            #"[HKEY_CURRENT_USER\Software\Wine\X11 Driver]"#
        ]
        if desired.emulateModeset {
            lines.append(#""EmulateModeset"="Y""#)
        } else {
            lines.append(#""EmulateModeset"=-"#)
        }
        try await importer(lines.joined(separator: "\r\n") + "\r\n", bottle)
        try desired.save(to: bottle.url)
    }
}
