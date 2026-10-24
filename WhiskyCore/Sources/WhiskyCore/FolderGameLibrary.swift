//
//  FolderGameLibrary.swift
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

/// Folder identities are independent of the executable selected on first run.
public struct FolderGameLibrary: Codable, Sendable {
    public var roots: [String] = []
    public var assignedFolders: [String] = []
    public var excludedFolders: Set<String> = []
    public var executables: [String: String] = [:]
    public var knownFolders: [String] = []
    public var automaticMetadata = true
    public var initializedRoots: Set<String> = []
    public var pendingMetadata: Set<String> = []

    private enum CodingKeys: String, CodingKey {
        case roots, assignedFolders, excludedFolders, executables, knownFolders
        case automaticMetadata, initializedRoots, pendingMetadata
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        roots = try values.decodeIfPresent([String].self, forKey: .roots) ?? []
        assignedFolders = try values.decodeIfPresent([String].self, forKey: .assignedFolders) ?? []
        excludedFolders = try values.decodeIfPresent(Set<String>.self, forKey: .excludedFolders) ?? []
        executables = try values.decodeIfPresent([String: String].self, forKey: .executables) ?? [:]
        knownFolders = try values.decodeIfPresent([String].self, forKey: .knownFolders) ?? []
        automaticMetadata = try values.decodeIfPresent(Bool.self, forKey: .automaticMetadata) ?? true
        initializedRoots = try values.decodeIfPresent(Set<String>.self, forKey: .initializedRoots) ?? Set(roots)
        pendingMetadata = try values.decodeIfPresent(Set<String>.self, forKey: .pendingMetadata) ?? []
    }

    public init() {}

    public static func load(bottleURL: URL) throws -> Self {
        let url = location(bottleURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    public func save(bottleURL: URL) throws {
        try JSONEncoder().encode(self).write(to: Self.location(bottleURL), options: .atomic)
    }

    public static func key(for url: URL, bottleURL: URL) -> String {
        let path = url.standardizedFileURL.path
        let root = bottleURL.standardizedFileURL.path + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    public static func url(for key: String, bottleURL: URL) -> URL {
        key.hasPrefix("/") ? URL(fileURLWithPath: key) : bottleURL.appendingPathComponent(key)
    }

    private func isExcluded(_ url: URL, key: String, bottleURL: URL) -> Bool {
        if excludedFolders.contains(key) || excludedFolders.contains(url.standardizedFileURL.path) {
            return true
        }
        let targetPath = url.standardizedFileURL.path
        return excludedFolders.contains {
            Self.url(for: $0, bottleURL: bottleURL).standardizedFileURL.path == targetPath
        }
    }

    private func isSteamDirectory(_ canonicalPath: String, steamDirectories: [URL]) -> Bool {
        steamDirectories.contains {
            let path = $0.resolvingSymlinksInPath().standardizedFileURL.path
            return canonicalPath == path || canonicalPath.hasPrefix(path + "/") || path.hasPrefix(canonicalPath + "/")
        }
    }

    // swiftlint:disable cyclomatic_complexity function_body_length
    /// Only direct child folders, never executable discovery or recursive walks.
    /// An unavailable root keeps its last known entries rather than deleting them.
    public mutating func scan(
        bottleURL: URL, steamDirectories: [URL],
        onScanFailure: (URL, any Error) -> Void = { _, _ in }
    ) -> [LibraryEntry] {
        let fileManager = FileManager.default
        var found = Set<String>()
        for rootKey in roots {
            let firstScan = !initializedRoots.contains(rootKey)
            let root = Self.url(for: rootKey, bottleURL: bottleURL)
            let children: [URL]
            do { children = try fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) } catch {
                onScanFailure(root, error)
                found.formUnion(knownFolders.filter {
                    let childURL = Self.url(for: $0, bottleURL: bottleURL)
                    return childURL.deletingLastPathComponent().standardizedFileURL.path
                        == root.standardizedFileURL.path
                        && !isExcluded(childURL, key: $0, bottleURL: bottleURL)
                })
                continue
            }
            for child in children {
                let values: URLResourceValues
                do { values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) } catch {
                    onScanFailure(child, error)
                    let key = Self.key(for: child, bottleURL: bottleURL)
                    if knownFolders.contains(key), !isExcluded(child, key: key, bottleURL: bottleURL) {
                        found.insert(key)
                    }
                    continue
                }
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let canonical = child.resolvingSymlinksInPath().standardizedFileURL.path
                // Do not treat a Steam install, its libraries, or an installed
                // Steam game as a second direct-executable launch path.
                guard !isSteamDirectory(canonical, steamDirectories: steamDirectories) else { continue }
                let key = Self.key(for: child, bottleURL: bottleURL)
                guard !isExcluded(child, key: key, bottleURL: bottleURL) else { continue }
                found.insert(key)
                if firstScan, automaticMetadata {
                    pendingMetadata.insert(key)
                }
            }
            initializedRoots.insert(rootKey)
        }
        for assignedKey in assignedFolders {
            let folder = Self.url(for: assignedKey, bottleURL: bottleURL)
            let normalizedKey = Self.key(for: folder, bottleURL: bottleURL)
            guard !isExcluded(folder, key: normalizedKey, bottleURL: bottleURL) else { continue }
            if let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let canonical = folder.resolvingSymlinksInPath().standardizedFileURL.path
                guard !isSteamDirectory(canonical, steamDirectories: steamDirectories) else { continue }
                found.insert(normalizedKey)
            } else {
                onScanFailure(folder, CocoaError(.fileReadUnknown))
                if knownFolders.contains(normalizedKey) || knownFolders.contains(assignedKey) {
                    found.insert(normalizedKey)
                }
            }
        }
        knownFolders = found.sorted()
        return knownFolders.map { key in
            let folder = Self.url(for: key, bottleURL: bottleURL)
            return LibraryEntry(
                id: "folder:\(bottleURL.path):\(key)", name: folder.lastPathComponent,
                iconURL: executables[key].map { Self.url(for: $0, bottleURL: bottleURL) },
                bottleURL: bottleURL, source: .folder, launch: .program(folder)
            )
        }
    }

    // swiftlint:enable cyclomatic_complexity function_body_length

    public func executable(for folder: URL, bottleURL: URL) -> URL? {
        executables[Self.key(for: folder, bottleURL: bottleURL)].map { Self.url(for: $0, bottleURL: bottleURL) }
    }

    private static func location(_ bottle: URL) -> URL {
        bottle.appendingPathComponent("Folder Games.json")
    }
}

/// Library-only removal never changes pins, installed games or launch settings.
public struct LibraryVisibility: Codable, Sendable {
    public var hiddenIdentities: Set<String> = []
    public var includePinnedAndSteam = true
    public init() {}
    public static func load(bottleURL: URL) throws -> Self {
        let url = bottleURL.appendingPathComponent("Library Visibility.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    public func save(bottleURL: URL) throws {
        try JSONEncoder().encode(self).write(
            to: bottleURL.appendingPathComponent("Library Visibility.json"),
            options: .atomic
        )
    }

    public func isHidden(_ entry: LibraryEntry) -> Bool {
        hiddenIdentities.contains(entry.metadataIdentity)
    }

    public mutating func setHidden(_ hidden: Bool, for entry: LibraryEntry) {
        if hidden {
            hiddenIdentities.insert(entry.metadataIdentity)
        } else {
            hiddenIdentities.remove(entry.metadataIdentity)
        }
    }

    public func includes(_ entry: LibraryEntry) -> Bool {
        includes(entry, showHidden: false)
    }

    public func includes(_ entry: LibraryEntry, showHidden: Bool) -> Bool {
        (showHidden || !isHidden(entry)) && (includePinnedAndSteam || entry.source == .folder)
    }
}
