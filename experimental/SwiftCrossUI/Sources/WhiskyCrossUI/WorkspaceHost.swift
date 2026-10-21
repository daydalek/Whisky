//
//  WorkspaceHost.swift
//  WhiskyCrossUI
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
import WhiskyCore
#if os(macOS)
import AppKit
import WhiskyKit
#endif

@MainActor
enum WorkspaceHost {
    #if os(macOS)
    private static var bottles: [URL: (bottle: Bottle, data: Data)] = [:]

    static func bottle(at url: URL) -> Bottle? {
        if let existing = bottles[url] {
            return existing.bottle
        }
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Metadata.plist")),
              (try? PropertyListDecoder().decode(BottleSettings.self, from: data)) != nil
        else { return nil }
        let bottle = Bottle(bottleUrl: url, isAvailable: true, cleanInvalidPins: false)
        bottles[url] = (bottle, data)
        return bottle
    }
    #endif

    static func invalidate(_ url: URL) {
        #if os(macOS)
        bottles[url] = nil
        #endif
    }

    static func refresh(_ containers: Set<URL>) {
        #if os(macOS)
        bottles = bottles.filter { containers.contains($0.key) }
        for (url, cached) in bottles {
            let current = try? Data(contentsOf: url.appendingPathComponent("Metadata.plist"))
            if current != cached.data {
                bottles[url] = nil
            }
        }
        #endif
    }

    static func applyConfiguration(
        _ field: ConfigurationField,
        value: ConfigurationValue,
        values: [String: ConfigurationValue],
        container: URL
    ) async throws {
        #if os(macOS)
        guard !ProcessInfo.processInfo.arguments.contains("--browse-only") else { return }
        let registryFields: Set = [
            "windowsVersion",
            "virtualDesktopEnabled",
            "resolutionPreset",
            "customResolutionWidth",
            "customResolutionHeight"
        ]
        guard registryFields.contains(field.id) else { return }
        guard let bottle = bottle(at: container) else { throw CocoaError(.fileReadCorruptFile) }
        if field.id == "windowsVersion", case let .text(raw) = value, let version = WinVersion(rawValue: raw) {
            _ = try await Wine.changeWinVersion(bottle: bottle, win: version)
            return
        }
        var updated = values
        updated[field.id] = value
        if updated["virtualDesktopEnabled"] == .boolean(true) {
            try await Wine.enableVirtualDesktop(bottle: bottle, resolution: resolutionString(updated))
        } else if field.id == "virtualDesktopEnabled" {
            try await Wine.disableVirtualDesktop(bottle: bottle)
        }
        #endif
    }

    #if os(macOS)
    private static func resolutionString(_ updated: [String: ConfigurationValue]) throws -> String {
        switch updated["resolutionPreset"] {
        case .text("custom"):
            guard case let .integer(width) = updated["customResolutionWidth"],
                  case let .integer(height) = updated["customResolutionHeight"]
            else { throw CocoaError(.coderInvalidValue) }
            return "\(width)x\(height)"
        case .text("matchDisplay"):
            if let screen = NSScreen.main {
                let width = Int(screen.frame.width * screen.backingScaleFactor)
                let height = Int(screen.frame.height * screen.backingScaleFactor)
                return "\(width)x\(height)"
            } else {
                return "1920x1080"
            }
        case let .text(raw): return String(raw.dropFirst())
        default: throw CocoaError(.coderInvalidValue)
        }
    }
    #endif
}
