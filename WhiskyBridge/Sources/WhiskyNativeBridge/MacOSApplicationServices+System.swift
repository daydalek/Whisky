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
import UniformTypeIdentifiers
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
        case "system.chooseFolder":
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            if let raw = params["path"]?.string, raw.hasPrefix("/") {
                panel.directoryURL = URL(fileURLWithPath: raw)
            }
            if let prompt = params["prompt"]?.string, !prompt.isEmpty {
                panel.prompt = prompt
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let url = panel.url else {
                return .object(["path": .null])
            }
            return .object(["path": .string(url.path)])
        case "system.choosePath":
            return try choosePath(params: params)
        case "system.chooseFolders":
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            panel.canCreateDirectories = true
            if let raw = params["path"]?.string, raw.hasPrefix("/") {
                panel.directoryURL = URL(fileURLWithPath: raw)
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK else {
                return .object(["paths": .array([])])
            }
            return .object(["paths": .array(panel.urls.map { .string($0.path) })])
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

    /// A file, folder or save destination picker. `purpose` is echoed back so
    /// one reply channel can serve Run, Move, Export and future callers.
    func choosePath(params: [String: JSONValue]) throws -> JSONValue {
        let purpose = params["purpose"]?.string ?? ""
        let mode = params["mode"]?.string ?? "file"
        let name = params["name"]?.string
        let extensions: [String] = if case let .array(items)? = params["extensions"] {
            items.compactMap(\.string)
        } else {
            []
        }
        let types = extensions.compactMap { UTType(filenameExtension: $0) }
        let start = params["path"]?.string.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }

        NSApplication.shared.activate(ignoringOtherApps: true)
        let url: URL?
        switch mode {
        case "save":
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            if !types.isEmpty {
                panel.allowedContentTypes = types
                panel.allowsOtherFileTypes = false
            }
            if let name, !name.isEmpty {
                panel.nameFieldStringValue = name
            }
            if let start {
                panel.directoryURL = start.hasDirectoryPath ? start : start.deletingLastPathComponent()
            }
            url = panel.runModal() == .OK ? panel.url : nil
        case "folder":
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.directoryURL = start
            url = panel.runModal() == .OK ? panel.url : nil
        default:
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            if !types.isEmpty {
                panel.allowedContentTypes = types
            }
            panel.directoryURL = start
            url = panel.runModal() == .OK ? panel.url : nil
        }
        return .object([
            "purpose": .string(purpose),
            "path": url.map { .string($0.path) } ?? .null
        ])
    }
}
