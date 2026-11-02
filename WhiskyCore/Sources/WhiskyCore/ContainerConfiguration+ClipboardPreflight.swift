//
//  ContainerConfiguration+ClipboardPreflight.swift
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

public extension ConfigurationFile {
    func clipboardPreflightConfiguration() throws -> ( // swiftlint:disable:this large_tuple
        launcher: LauncherType?,
        policy: ClipboardPolicy,
        threshold: Int
    ) {
        let fields = ContainerConfiguration.fields.filter {
            ["detectedLauncher", "clipboardPolicy", "clipboardThreshold"].contains($0.id)
        }
        let values = try values(for: fields)
        let launcher: LauncherType? = if case let .text(raw) = values["detectedLauncher"], !raw.isEmpty {
            LauncherType(rawValue: raw)
        } else {
            nil
        }
        let policy: ClipboardPolicy = if case let .text(raw) = values["clipboardPolicy"],
                                         let resolved = ClipboardPolicy(rawValue: raw) {
            resolved
        } else {
            .auto
        }
        let threshold: Int = if case let .integer(value) = values["clipboardThreshold"] {
            value
        } else {
            ClipboardPreflight.largeContentThreshold
        }
        return (launcher: launcher, policy: policy, threshold: threshold)
    }
}
