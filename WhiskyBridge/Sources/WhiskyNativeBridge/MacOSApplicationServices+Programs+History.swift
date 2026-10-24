//
//  MacOSApplicationServices+Programs+History.swift
//  WhiskyNativeBridge
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

import AppKit
import Foundation
import WhiskyApplication
import WhiskyBridgeProtocol
import WhiskyCore
import WhiskyKit

extension MacOSApplicationServices {
    // MARK: - Shortcut

    func createShortcut(
        _ params: [String: JSONValue],
        target: ProgramTarget
    ) async throws -> JSONValue {
        guard FileManager.default.fileExists(atPath: target.executable.path) else {
            throw BridgeFailure("file_missing", "The selected executable is unavailable")
        }
        let destination = try params.path("destination")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { throw BridgeFailure("invalid_params", "Expected an existing destination directory") }

        let name: String = if let custom = params["name"]?.string {
            custom
        } else {
            target.executable.deletingPathExtension().lastPathComponent
        }
        guard !name.isEmpty, name.utf8.count <= 128,
              !name.contains("/"), !name.contains(":"), !name.contains("\0")
        else { throw BridgeFailure("invalid_params", "Invalid shortcut name") }
        let appURL = destination.appendingPathComponent(name).appendingPathExtension("app")
        guard !FileManager.default.fileExists(atPath: appURL.path) else {
            throw BridgeFailure("destination_exists", "A shortcut already exists at that path")
        }

        let liveTarget = ShortcutCreator.liveTarget(for: target.executable, bottle: target.bottle)
        let launchScript = ShortcutCreator.liveLaunchScript(for: liveTarget)
        try ShortcutCreator.createShortcutBundle(at: appURL, launchScript: launchScript, name: name)
        let icon = await IconCache.shared.iconOrFallback(for: target.executable)
        NSWorkspace.shared.setIcon(icon, forFile: appURL.path, options: [])
        NSWorkspace.shared.activateFileViewerSelecting([appURL])
        return .object([
            "path": .string(appURL.path),
            "name": .string(name)
        ])
    }
}
