//
//  ContainerPrograms.swift
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

public struct ContainerProgram: Identifiable, Sendable {
    public let url: URL
    public let name: String
    public let pinned: Bool
    public let blocked: Bool
    public var id: URL {
        url
    }

    public var available: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func entry(in container: URL) -> LibraryEntry {
        LibraryEntry(
            id: "pinned:\(url.path)",
            name: name,
            iconURL: url,
            bottleURL: container,
            source: .pinned,
            launch: .program(url),
            launcher: LauncherType.detect(from: url)
        )
    }
}

extension ConfigurationFile {
    /// Library refresh reads declared pins directly, independently of installed-program discovery.
    /// The blocklist controls the program browser; library visibility has its own persisted rules.
    public func pinnedPrograms() throws -> [ContainerProgram] {
        let (document, _) = try load()
        let info = try Self.programInfo(document)
        let blocked = try Set(Self.blocklist(info).map(Self.canonical))
        return try Self.pins(info).compactMap { pin in
            guard let url = try Self.decodeURL(pin["url"]) else { return nil }
            return ContainerProgram(
                url: url,
                name: pin["name"] as? String ?? url.deletingPathExtension().lastPathComponent,
                pinned: true,
                blocked: blocked.contains(Self.canonical(url))
            )
        }
    }

    /// Includes hidden executables so the program page can restore them.
    public func programs(in container: URL) throws -> [ContainerProgram] {
        let (document, _) = try load()
        let info = try Self.programInfo(document)
        let pins = try Self.pins(info)
        let blocked = try Self.blocklist(info)
        var records: [URL: ContainerProgram] = [:]
        let blockedKeys = Set(blocked.map(Self.canonical))
        let discovered = InstalledPrograms.discoverInstalledExecutables(
            driveC: container.appendingPathComponent("drive_c"),
            blocklist: []
        )
        for url in discovered + blocked {
            let key = Self.canonical(url)
            records[key] = ContainerProgram(
                url: url,
                name: url.deletingPathExtension().lastPathComponent,
                pinned: false,
                blocked: blockedKeys.contains(key)
            )
        }
        for pin in pins {
            if let url = try Self.decodeURL(pin["url"]) {
                let key = Self.canonical(url)
                records[key] = ContainerProgram(
                    url: url,
                    name: pin["name"] as? String ?? url.deletingPathExtension().lastPathComponent,
                    pinned: true,
                    blocked: blockedKeys.contains(key)
                )
            }
        }
        return records.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func setPinned(_ pinned: Bool, executable: URL, name: String, removable: Bool = false) throws {
        try mutate { document in
            var info = try Self.programInfo(document)
            var pins = try Self.pins(info)
            let index = try pins.firstIndex { pin in
                try Self.decodeURL(pin["url"]).map(Self.canonical) == Self.canonical(executable)
            }
            if pinned {
                var pin: [String: Any] = index.map { pins[$0] } ?? ["removable": removable]
                pin["name"] = name
                pin["url"] = try Self.encodeURL(executable)
                if let index {
                    pins[index] = pin
                } else {
                    pins.append(pin)
                }
            } else if let index {
                pins.remove(at: index)
            }
            info["pins"] = pins
            document["info"] = info
        }
    }

    public func setBlocked(_ blocked: Bool, executable: URL) throws {
        try mutate { document in
            var info = try Self.programInfo(document)
            var list = try Self.blocklist(info)
            list.removeAll { Self.canonical($0) == Self.canonical(executable) }
            if blocked {
                list.append(executable)
            }
            info["blocklist"] = try list.map(Self.encodeURL)
            document["info"] = info
        }
    }

    private static func programInfo(_ document: [String: Any]) throws -> [String: Any] {
        guard let value = document["info"] else { return [:] }
        guard let info = value as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        return info
    }

    private static func pins(_ info: [String: Any]) throws -> [[String: Any]] {
        guard let value = info["pins"] else { return [] }
        guard let pins = value as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
        return pins
    }

    private static func blocklist(_ info: [String: Any]) throws -> [URL] {
        guard let value = info["blocklist"] else { return [] }
        guard let list = value as? [Any] else { throw CocoaError(.fileReadCorruptFile) }
        return try list.map { value in
            guard let url = try decodeURL(value) else { throw CocoaError(.fileReadCorruptFile) }
            return url
        }
    }

    private static func encodeURL(_ url: URL) throws -> Any {
        struct Wrapper: Encodable { let url: URL }
        let data = try PropertyListEncoder().encode(Wrapper(url: url))
        guard let value = try (PropertyListSerialization
            .propertyList(from: data, format: nil) as? [String: Any])?["url"]
        else { throw CocoaError(.coderInvalidValue) }
        return value
    }

    private static func decodeURL(_ value: Any?) throws -> URL? {
        guard let value else { return nil }
        struct Wrapper: Decodable { let url: URL }
        let data = try PropertyListSerialization.data(fromPropertyList: ["url": value], format: .binary, options: 0)
        return try PropertyListDecoder().decode(Wrapper.self, from: data).url
    }

    private static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}
