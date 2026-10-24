//
//  DesktopEntryUpdate.swift
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

/// Recognizes the generated launch boundary and preserves user display fields/groups.
enum DesktopEntryUpdate {
    struct Document {
        var lines: [String]
        let start: Int
        let end: Int
        let fields: [String: String]
        let positions: [String: Int]

        init(_ data: Data) throws {
            guard data.count <= 65_536, let text = String(bytes: data, encoding: .utf8),
                  !text.contains("\0")
            else { throw modified() }
            lines = text.components(separatedBy: "\n")
            var group: String?
            var start: Int?
            var end: Int?
            var fields: [String: String] = [:]
            var positions: [String: Int] = [:]
            for (index, raw) in lines.enumerated() {
                let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
                if line.hasPrefix("[") {
                    if group == "[Desktop Entry]" {
                        end = index
                    }
                    group = line
                    if group == "[Desktop Entry]" {
                        guard start == nil else { throw modified() }
                        start = index
                    }
                } else if group == "[Desktop Entry]", !line.isEmpty, !line.hasPrefix("#") {
                    guard let equal = line.firstIndex(of: "=") else { throw modified() }
                    let key = String(line[..<equal])
                    guard !key.isEmpty, fields[key] == nil else { throw modified() }
                    fields[key] = String(line[line.index(after: equal)...])
                    positions[key] = index
                }
            }
            guard let start else { throw modified() }
            self.start = start
            self.end = end ?? lines.count
            self.fields = fields
            self.positions = positions
        }
    }

    static func merge(_ existing: Data, desired: String, arguments: [[String]], handlesFiles: Bool) throws -> Data {
        var old = try Document(existing)
        let next = try Document(Data(desired.utf8))
        guard old.fields["X-Whisky-Managed"] == "true" else { throw foreign() }
        guard let rawLauncher = old.fields["X-Whisky-Launcher"], let launcher = decode(rawLauncher),
              launcher.hasPrefix("/"), !launcher.contains("\0"), old.fields["Type"] == "Application",
              old.fields["Terminal"] == "false"
        else { throw modified() }
        let recognized = try arguments.contains { args in
            let template = LinuxDesktopEntry.contents(
                name: "Whisky",
                launcher: URL(fileURLWithPath: launcher),
                arguments: args,
                handlesFiles: handlesFiles
            )
            return try Document(Data(template.utf8)).fields["Exec"] == old.fields["Exec"]
        }
        guard recognized else { throw modified() }
        var patch: [String: String] = [:]
        for key in ["Exec", "X-Whisky-Launcher"] {
            patch[key] = next.fields[key]
        }
        if handlesFiles {
            let previous = (old.fields["MimeType"] ?? "").split(separator: ";").map(String.init)
            let required = (next.fields["MimeType"] ?? "").split(separator: ";").map(String.init)
            patch["MimeType"] = (previous + required.filter { !previous.contains($0) }).joined(separator: ";") + ";"
        }
        for (key, value) in next.fields where old.fields[key] == nil {
            patch[key] = value
        }
        let carriageReturn = old.lines[old.start].hasSuffix("\r") ? "\r" : ""
        for (key, value) in patch {
            if let index = old.positions[key] {
                old.lines[index] = key + "=" + value + carriageReturn
            }
        }
        let additions = patch.keys.filter { old.positions[$0] == nil }.sorted().compactMap { key in
            patch[key].map { key + "=" + $0 + carriageReturn }
        }
        old.lines.insert(contentsOf: additions, at: old.end)
        return Data(old.lines.joined(separator: "\n").utf8)
    }

    private static func decode(_ value: String) -> String? {
        var result = ""
        var escaped = false
        for character in value {
            if escaped {
                switch character {
                case "s": result += " "
                case "n": result += "\n"
                case "r": result += "\r"
                case "t": result += "\t"
                case "\\": result += "\\"
                default: return nil
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return escaped ? nil : result
    }

    static func modified() -> BridgeFailure {
        BridgeFailure(
            "desktop_modified",
            "The desktop launch command was edited; preserve it and choose another shortcut name or directory"
        )
    }

    static func foreign() -> BridgeFailure {
        BridgeFailure(
            "destination_exists",
            "An unmanaged desktop entry already exists; preserve it and choose another destination"
        )
    }
}
