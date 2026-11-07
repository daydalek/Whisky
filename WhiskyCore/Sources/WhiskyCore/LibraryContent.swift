//
//  LibraryContent.swift
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

/// A scan result remains separate from publication so callers can fence stale requests.
public struct LibraryDiscovery: Sendable {
    public let containerURL: URL
    public let entries: [LibraryEntry]
    public let folders: FolderGameLibrary

    public init(containerURL: URL, entries: [LibraryEntry], folders: FolderGameLibrary) {
        self.containerURL = containerURL
        self.entries = entries
        self.folders = folders
    }

    public static func scan(
        in containerURL: URL, folders: FolderGameLibrary,
        additionalEntries: [LibraryEntry] = [], excluding steamDirectories: [URL] = []
    ) -> LibraryDiscovery {
        var scanned = folders
        let entries = scanned.scan(bottleURL: containerURL, steamDirectories: steamDirectories)
        return LibraryDiscovery(
            containerURL: containerURL,
            entries: dropDuplicateLaunchTargets(
                LibraryCatalogue.merge([additionalEntries, entries]),
                folders: scanned, bottleURL: containerURL
            ),
            folders: scanned
        )
    }

    /// The synthesized Steam client entry stands in for the real `steam.exe`
    /// only until a pin or a folder entry names the same executable; a
    /// user-curated entry wins over the placeholder every time.
    private static func dropDuplicateLaunchTargets(
        _ entries: [LibraryEntry], folders: FolderGameLibrary, bottleURL: URL
    ) -> [LibraryEntry] {
        var covered = Set<String>()
        for entry in entries where !entry.id.hasPrefix("steam-client:") {
            guard case let .program(url) = entry.launch else { continue }
            if entry.source == .folder {
                if let executable = folders.executable(for: url, bottleURL: bottleURL) {
                    covered.insert(executable.standardizedFileURL.path)
                }
            } else {
                covered.insert(url.standardizedFileURL.path)
            }
        }
        return entries.filter { entry in
            guard entry.id.hasPrefix("steam-client:"),
                  case let .program(url) = entry.launch
            else { return true }
            return !covered.contains(url.standardizedFileURL.path)
        }
    }

    /// Retain settings changed during scanning while publishing derived folder state.
    @discardableResult
    public func apply(to current: inout FolderGameLibrary) -> Bool {
        guard current.roots == folders.roots,
              current.assignedFolders == folders.assignedFolders,
              current.excludedFolders == folders.excludedFolders,
              !current.roots.isEmpty || !current.assignedFolders.isEmpty
        else { return false }
        current.knownFolders = folders.knownFolders
        current.initializedRoots = folders.initializedRoots
        current.pendingMetadata.formUnion(folders.pendingMetadata)
        return true
    }
}

/// Content side effects are composed by the host; UI models own presentation and request lifetimes.
@MainActor
public protocol LibraryContentProviding: AnyObject {
    func discover(in containerURL: URL) async throws -> LibraryDiscovery
    func commit(_ discovery: LibraryDiscovery) throws
    func visibility(in containerURL: URL) throws -> LibraryVisibility
    func setHidden(_ hidden: Bool, for entry: LibraryEntry) throws -> LibraryVisibility
    func activity(for entry: LibraryEntry) throws -> GameActivity
    func activities(for entries: [LibraryEntry]) async throws -> [String: GameActivity]
    func move(_ entry: LibraryEntry, to containerURL: URL, hidden: Bool) async throws -> LibraryEntry
}
