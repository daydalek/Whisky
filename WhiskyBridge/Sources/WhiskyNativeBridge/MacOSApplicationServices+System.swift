//
//  MacOSApplicationServices+System.swift
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

// MARK: - System methods and display resolution

extension MacOSApplicationServices {
    func virtualDesktopResolution(_ values: [String: ConfigurationValue]) throws -> String {
        if values["resolutionPreset"] == .text("matchDisplay"), NSScreen.main == nil {
            throw BridgeFailure("display_unavailable", "Display dimensions are unavailable")
        }
        guard let resolution = ContainerConfiguration.virtualDesktopResolution(
            from: values,
            displayDimensions: {
                guard let screen = NSScreen.main else { return nil }
                let scale = screen.backingScaleFactor
                return (
                    width: Int(screen.frame.width * scale),
                    height: Int(screen.frame.height * scale)
                )
            }
        ) else {
            throw BridgeFailure("invalid_params", "Resolution preset is unavailable")
        }
        return resolution
    }

    func systemCall(
        _ method: String,
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) throws -> JSONValue {
        switch method {
        case "system.resources":
            return .object([
                "kitBundle": .string(WhiskyResources.kitBundleURL.path),
                "tools": .object(Dictionary(uniqueKeysWithValues: ["cabextract", "winetricks", "verbs.txt"].map {
                    ($0, WhiskyResources.tool($0).map { .string($0.path) } ?? .null)
                }))
            ])
        case "system.reveal", "system.open":
            let container = try workspace.resolve(params)
            let path = params["path"] == nil ? container : try params.path("path")
            guard FileManager.default.fileExists(atPath: path.path) else { throw BridgeFailure(
                "file_missing",
                "Selected file is unavailable"
            ) }
            if method == "system.reveal" {
                NSWorkspace.shared.activateFileViewerSelecting([path])
            } else if !NSWorkspace.shared.open(path) {
                throw BridgeFailure(
                    "host_failed",
                    "macOS could not open the selected file"
                )
            }
            return .object(["accepted": .bool(true)])
        default:
            throw BridgeFailure("method_unavailable", "Native method is unavailable")
        }
    }
}
