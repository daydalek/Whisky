//
//  ProgramSettings+Presets.swift
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

public enum WineD3DRenderer: String, CaseIterable, Sendable {
    case automatic = ""
    case gdi
    case openGL = "gl"
    case vulkan
}

public extension ProgramSettings {
    /// Writes a locale preset into the saved environment and the locale picker.
    mutating func applyLocalePreset(_ preset: Locales) {
        locale = preset
        for key in ["LANG", "LC_ALL"] {
            environment[key] = preset == .auto ? nil : preset.rawValue
        }
    }

    /// The renderer selected in WINE_D3D_CONFIG. Unknown values remain custom.
    var wineD3DRenderer: WineD3DRenderer? {
        for entry in environment["WINE_D3D_CONFIG", default: ""].split(separator: ",") {
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.first?.trimmingCharacters(in: .whitespaces) == "renderer", parts.count == 2 {
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                return value == "no3d" ? .gdi : WineD3DRenderer(rawValue: value)
            }
        }
        return .automatic
    }

    /// Changes only the renderer, retaining the user's other WineD3D options.
    mutating func applyWineD3DRenderer(_ renderer: WineD3DRenderer) {
        var entries = environment["WINE_D3D_CONFIG", default: ""].split(separator: ",").filter {
            $0.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) != "renderer"
        }.map(String.init)
        if renderer != .automatic {
            entries.append("renderer=\(renderer.rawValue)")
        }
        environment["WINE_D3D_CONFIG"] = entries.isEmpty ? nil : entries.joined(separator: ",")
    }
}
