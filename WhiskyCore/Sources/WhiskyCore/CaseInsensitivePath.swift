//
//  CaseInsensitivePath.swift
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

/// Thread-safe `[parentPath: entries]` cache for directory listings.
private final class DirectoryListingCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: [String]] = [:]

    func entries(atPath path: String) -> [String]? {
        lock.lock()
        if let cached = cache[path] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return nil
        }
        lock.lock()
        cache[path] = entries
        lock.unlock()
        return entries
    }
}

/// Resolves Windows and Wine prefix paths across case-sensitive POSIX filesystems.
public enum CaseInsensitivePath {
    /// Caches directory listings so repeated resolves do not re-enumerate the same parents.
    private static let listingCache = DirectoryListingCache()

    private static func directoryEntries(atPath path: String) -> [String]? {
        listingCache.entries(atPath: path)
    }

    public static func resolve(
        base: URL,
        components: [String],
        forceDirectoryLookup: Bool = false
    ) -> URL {
        let fileManager = FileManager.default
        var current = base
        for component in components where !component.isEmpty {
            let exact = current.appending(path: component)
            if !forceDirectoryLookup, fileManager.fileExists(atPath: exact.path(percentEncoded: false)) {
                current = exact
                continue
            }
            let parentPath = current.path(percentEncoded: false)
            guard let entries = directoryEntries(atPath: parentPath) else {
                current = exact
                continue
            }
            if entries.contains(component) {
                current = exact
                continue
            }
            let lowered = component.lowercased()
            if let match = entries.sorted().first(where: { $0.lowercased() == lowered }) {
                current = current.appending(path: match)
            } else {
                current = exact
            }
        }
        return current
    }

    public static func resolve(
        base: URL,
        relativePath: String,
        forceDirectoryLookup: Bool = false
    ) -> URL {
        let components = relativePath.split(separator: "/").map(String.init)
        return resolve(base: base, components: components, forceDirectoryLookup: forceDirectoryLookup)
    }
}
