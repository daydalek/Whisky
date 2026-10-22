//
//  ContainerRoutes.swift
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

/// The native GameRouting plist has legacy path strings and dated dictionaries.
/// Lifecycle patches preserve each shape, launch dates and opaque fields.
enum ContainerRoutes {
    static func location(_ registry: URL) -> URL {
        registry.deletingLastPathComponent().appendingPathComponent("GameRouting.plist")
    }

    static func sources(source: URL, paths: [URL], registry: URL) throws -> [String] {
        var result = Set(paths.filter { ContainerRegistry.canonical($0).path == source.path }
            .map { normalize($0.path) })
        result.insert(normalize(source.path))
        let url = location(registry)
        guard FileManager.default.fileExists(atPath: url.path) else { return result.sorted() }
        let lease = try ContainerRegistry.acquire(ApplicationWorkspace(registry: url))
        defer { ContainerRegistry.release(lease) }
        let (document, _) = try read(url)
        for (key, value) in document {
            guard validKey(key), let path = path(value), path.hasPrefix("/"),
                  ContainerRegistry.canonical(URL(fileURLWithPath: path)).path == source.path
            else { continue }
            result.insert(normalize(path))
        }
        return result.sorted()
    }

    static func apply(_ journal: ContainerJournal, registry: URL) throws {
        guard journal.kind != .duplicate else { return }
        let url = location(registry)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let lease = try ContainerRegistry.acquire(ApplicationWorkspace(registry: url))
        defer { ContainerRegistry.release(lease) }
        var (document, format) = try read(url)
        let sources = Set((journal.routeSources ?? [journal.source.path]).map(normalize))
        var changed = false
        for (key, value) in document {
            guard validKey(key), let old = path(value), old.hasPrefix("/"),
                  sources.contains(normalize(old))
            else { continue }
            if journal.kind == .remove {
                document[key] = nil
            } else if var fields = value as? [String: Any] {
                fields["bottle"] = normalize(journal.destination.path)
                document[key] = fields
            } else {
                document[key] = normalize(journal.destination.path)
            }
            changed = true
        }
        if changed {
            try PropertyListSerialization.data(fromPropertyList: document, format: format, options: 0)
                .write(to: url, options: .atomic)
        }
    }

    private static func validKey(_ value: String) -> Bool {
        Int(value).map { $0 > 0 } ?? false
    }

    private static func path(_ value: Any) -> String? {
        (value as? String) ?? (value as? [String: Any])?["bottle"] as? String
    }

    private static func normalize(_ path: String) -> String {
        var value = URL(fileURLWithPath: path).standardizedFileURL.path
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    private static func read(_ url: URL) throws -> ([String: Any], PropertyListSerialization.PropertyListFormat) {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw BridgeFailure("route_store_invalid", "Expected a regular route store: \(url.path)")
            }
            var format = PropertyListSerialization.PropertyListFormat.binary
            guard let document = try PropertyListSerialization.propertyList(
                from: ApplicationWorkspace.read(url), format: &format
            ) as? [String: Any]
            else {
                throw BridgeFailure("route_store_invalid", "Route store is unreadable: \(url.path)")
            }
            return (document, format)
        } catch let failure as BridgeFailure {
            throw failure
        } catch {
            throw BridgeFailure(
                "route_store_invalid",
                "Route store is unreadable: \(url.path): \(error.localizedDescription)"
            )
        }
    }
}
