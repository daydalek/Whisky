//
//  LibraryEntry.swift
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

/// Where a library entry came from.
///
/// A raw-value type rather than an enum so a launcher can be added without
/// recompiling everything that switches over the existing ones.
public struct LibrarySourceID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Programs the user pinned. The library shows these and not every
    /// executable found in a prefix: a Windows install is full of uninstallers,
    /// crash handlers and redistributables, and a library that lists them is a
    /// file browser rather than a library.
    public static let pinned = LibrarySourceID(rawValue: "pinned")
    /// Games installed through the Steam client inside a bottle.
    public static let steam = LibrarySourceID(rawValue: "steam")
    public static let folder = LibrarySourceID(rawValue: "folder")
}

/// One thing a person can launch, whatever put it there.
public struct LibraryEntry: Identifiable, Hashable, Sendable {
    /// How to start it. Sources that need their own launch path add a case;
    /// everything else in the library stays the same.
    public enum Launch: Hashable, Sendable {
        /// An executable inside the bottle, run directly.
        case program(URL)
        /// A Steam app, run through the client so Steam sees it as a launch.
        case steam(appID: Int)
    }

    public let id: String
    public let name: String
    /// The executable to read an icon out of, when there is one.
    public let iconURL: URL?
    /// Wide artwork for this entry, when the source has some on disk. Steam
    /// caches its own banners inside the bottle, so a Steam game shows the art
    /// its store page uses without anything being fetched.
    public let artworkURL: URL?
    public let bottleURL: URL
    public let source: LibrarySourceID
    public let launch: Launch
    /// Whether this entry is a storefront client rather than a game.
    ///
    /// A launcher is worth keeping in the library, since it is how you reach an
    /// account, a store and an update. It is not what somebody scanning the grid
    /// is looking for, so it is labelled and sorted below the games.
    public let launcher: LauncherType?

    public var isLauncher: Bool {
        launcher != nil
    }

    public init(
        id: String,
        name: String,
        iconURL: URL?,
        artworkURL: URL? = nil,
        bottleURL: URL,
        source: LibrarySourceID,
        launch: Launch,
        launcher: LauncherType? = nil
    ) {
        self.id = id
        self.name = name
        self.iconURL = iconURL
        self.artworkURL = artworkURL
        self.bottleURL = bottleURL
        self.source = source
        self.launch = launch
        self.launcher = launcher
    }
}

public enum LibraryCatalogue {
    /// Collapse repeated identities, not repeated titles. A pinned executable
    /// must never silently shadow a same-named Steam App ID and bypass Steam.
    public static func merge(_ groups: [[LibraryEntry]]) -> [LibraryEntry] {
        var seenIDs = Set<String>()
        var items: [LibraryEntry] = []

        for group in groups {
            for item in group {
                guard seenIDs.insert(item.id).inserted else { continue }
                items.append(item)
            }
        }

        return items
    }
}

extension LibraryEntry {
    public var metadataIdentity: String {
        switch launch {
        case let .steam(appID): return "steam:\(appID)"
        case let .program(url):
            let root = bottleURL.standardizedFileURL.path + "/"
            let path = url.standardizedFileURL.path
            return "program:" + (path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path)
        }
    }

    public var metadataDirectory: URL {
        bottleURL.appendingPathComponent("Game Metadata", isDirectory: true)
    }
}
