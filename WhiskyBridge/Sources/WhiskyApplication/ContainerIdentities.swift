//
//  ContainerIdentities.swift
//  WhiskyBridge
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

/// Registry-resident identities share the atomic paths/lifecycle commit boundary.
enum ContainerIdentities {
    static let key = "whiskyContainerIdentities"

    static func read(_ values: [String: Any]) throws -> [String: [String: Any]] {
        guard let raw = values[key] else { return [:] }
        guard let entries = raw as? [String: [String: Any]], entries.count <= 4_096 else { throw invalid() }
        for (id, value) in entries {
            guard UUID(uuidString: id)?.uuidString == id, let path = value["path"] as? String,
                  path.hasPrefix("/"), let device = value["device"] as? String, UInt64(device) != nil,
                  let inode = value["inode"] as? String, UInt64(inode) != nil
            else { throw invalid() }
        }
        return entries
    }

    static func assign(_ source: URL, values: inout [String: Any]) throws -> String {
        var entries = try read(values)
        let identity = try DirectoryIdentity.require(source)
        if let existing = entries.first(where: { _, value in
            matches(value, identity)
        }) {
            return existing.key
        }
        guard entries.count < 4_096 else { throw BridgeFailure("identity_limit", "Container identity limit reached") }
        let id = UUID().uuidString
        entries[id] = ["path": source.path, "device": String(identity.device), "inode": String(identity.inode)]
        values[key] = entries
        return id
    }

    static func relocate(_ source: DirectoryIdentity, to destination: URL?, values: inout [String: Any]) throws {
        guard values[key] != nil else { return }
        var entries = try read(values)
        let identity = try destination.map(DirectoryIdentity.require)
        for (id, var entry) in entries where matches(entry, source) {
            if let destination, let identity {
                entry["path"] = destination.path
                entry["device"] = String(identity.device)
                entry["inode"] = String(identity.inode)
                entries[id] = entry
            } else {
                entries[id] = nil
            }
        }
        values[key] = entries
    }

    static func resolve(_ id: String, paths: [URL], values: [String: Any]) throws -> URL {
        guard let uuid = UUID(uuidString: id), let entry = try read(values)[uuid.uuidString] else {
            throw BridgeFailure("shortcut_unavailable", "The shortcut container identity is unavailable")
        }
        for path in paths {
            let source = ContainerRegistry.canonical(path)
            if let actual = try? DirectoryIdentity.require(source), matches(entry, actual) {
                return source
            }
        }
        throw BridgeFailure("shortcut_unavailable", "Import the original container or recreate this shortcut")
    }

    private static func matches(_ entry: [String: Any], _ identity: DirectoryIdentity) -> Bool {
        entry["device"] as? String == String(identity.device) && entry["inode"] as? String == String(identity.inode)
    }

    private static func invalid() -> BridgeFailure {
        BridgeFailure("identity_store_invalid", "Preserve and inspect the container identity records")
    }
}
