//
//  SteamLibrarySource.swift
//  WhiskyKit
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

/// The games a bottle's Steam client has installed.
public enum SteamLibrarySource: Sendable {
    public static let id = LibrarySourceID.steam

    /// Without the settings parameter, so a caller can run this off the main
    /// actor: enumerating Steam walks libraryfolders.vdf and every manifest in
    /// it, which is the one part of building the library that touches disk.
    public static func entries(inBottleAt url: URL) -> [LibraryEntry] {
        let steamRoot = SteamLibrary.detectInstall(bottleURL: url)
        return SteamLibrary.enumerate(bottleURL: url).map { game in
            LibraryEntry(
                // Scoped to the bottle, because the same game can be installed
                // in two of them and an id shared by two rows breaks the grid's
                // diffing rather than merely looking odd. A pin is already
                // scoped: its id carries the executable's full path.
                id: "steam:\(url.path(percentEncoded: false)):\(game.appId)",
                name: game.name,
                iconURL: steamRoot.flatMap { iconURL(appID: game.appId, steamRoot: $0) },
                artworkURL: steamRoot.flatMap { artworkURL(appID: game.appId, steamRoot: $0) },
                bottleURL: url,
                source: id,
                launch: .steam(appID: game.appId)
            )
        }
    }

    /// The best art Steam already cached for `appID`.
    ///
    /// Steam has changed this layout more than once: a flat `<appid>_header.jpg`,
    /// then `<appid>/header.jpg`, and now `<appid>/<hash>/library_header.jpg`.
    /// Matching on the filename rather than the path survives all three, and the
    /// next one as long as the names hold.
    ///
    /// Landscape first because that is the shape of a card. A portrait capsule
    /// is the fallback and gets cropped, which still beats an empty card.
    public static func artworkURL(appID: Int, steamRoot: URL) -> URL? {
        let landscape = ["library_header.jpg", "header.jpg", "\(appID)_header.jpg"]
        let portrait = ["library_capsule.jpg", "library_600x900.jpg", "\(appID)_library_600x900.jpg"]
        let cached = cachedFiles(appID: appID, steamRoot: steamRoot)

        for name in landscape + portrait {
            if let match = cached.first(where: { $0.lastPathComponent == name }) {
                return match
            }
        }
        return nil
    }

    /// The small square icon Steam caches beside the art, if it left one.
    ///
    /// It sits directly in the app's folder rather than in one of the hashed
    /// subfolders, which is what separates it from the artwork.
    public static func iconURL(appID: Int, steamRoot: URL) -> URL? {
        let folder = steamRoot.appending(path: "appcache").appending(path: "librarycache")
            .appending(path: "\(appID)")
        let contents = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey]
        )
        return contents?.first { $0.pathExtension.lowercased() == "jpg" }
    }

    /// Every cached file for one app, from either layout.
    ///
    /// Both are always checked rather than one being a fallback for the other:
    /// an enumerator over a folder that does not exist yields nothing instead of
    /// failing, so "did the walk work" cannot decide which layout is in use.
    private static func cachedFiles(appID: Int, steamRoot: URL) -> [URL] {
        let cache = steamRoot.appending(path: "appcache").appending(path: "librarycache")
        let walked = FileManager.default.enumerator(
            at: cache.appending(path: "\(appID)"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )?.compactMap { $0 as? URL } ?? []

        // The layout Steam used before it made a folder per app.
        let flat = ["\(appID)_header.jpg", "\(appID)_library_600x900.jpg"]
            .map { cache.appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }

        return walked + flat
    }
}
