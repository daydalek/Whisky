//
//  ContainerConfiguration+Platforms.swift
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

extension ContainerConfiguration {
    public static func sections(for platform: ConfigurationPlatform) -> [ConfigurationSection] {
        sections.compactMap { section in
            let fields = section.fields.compactMap { field -> ConfigurationField? in
                guard platform != .linux || !linuxUnavailableFields.contains(field.id) else { return nil }
                return field.filtered(for: platform)
            }
            return fields.isEmpty ? nil : ConfigurationSection(
                id: section.id, title: section.title, titleKey: section.titleKey, fields: fields
            )
        }
    }

    /// These settings require host services supplied by the macOS adapter.
    /// Keep their stored values intact when opening an imported bottle on Linux.
    public static let linuxUnavailableFields: Set<String> = [
        "avxEnabled", "launcherMode", "detectedLauncher", "autoEnableDXVK",
        "outputDeviceMode", "pinnedDeviceName", "discordPresence", "discordBridge",
        "clipboardPolicy", "clipboardThreshold", "closeWithProcessesPolicy"
    ]

    public static func fields(for platform: ConfigurationPlatform) -> [ConfigurationField] {
        sections(for: platform).flatMap(\.fields)
    }
}
