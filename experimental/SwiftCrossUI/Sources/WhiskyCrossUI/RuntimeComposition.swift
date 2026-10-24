//
//  RuntimeComposition.swift
//  WhiskyCrossUI
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
import WhiskyCore
#if os(macOS)
import WhiskyKit
#endif

/// Application composition connects validated containers to the production driver.
/// Browsing-only probes can explicitly disable Wine through --browse-only.
@MainActor
func makeWorkspaceRuntime(arguments: [String] = ProcessInfo.processInfo.arguments) -> any LibraryRuntime {
    #if os(macOS)
    if !arguments.contains("--browse-only") {
        let driver = WineLibraryRuntimeDriver(bottleResolver: { WorkspaceHost.bottle(at: $0) })
        return LibraryRuntimeController(driver: driver)
    }
    #endif
    return LibraryRuntimeController(driver: UnavailableLibraryRuntimeDriver())
}

/// Catalogue reads preserve the stored settings and keep host-specific sources in this file.
func readBrowserEntries(root: URL?, bottle: URL?, includingHidden: Bool = false) throws -> [LibraryEntry] {
    guard let container = bottle ?? root else { return [] }
    var folders = try bottle.map { try FolderGameLibrary.load(bottleURL: $0) } ?? FolderGameLibrary()
    if let root {
        folders.roots = [root.path]
    }
    let visibility = try bottle.map { try LibraryVisibility.load(bottleURL: $0) } ?? LibraryVisibility()
    var additional: [LibraryEntry] = []
    var steamDirectories: [URL] = []
    #if os(macOS)
    if let bottle {
        let metadata = bottle.appendingPathComponent("Metadata.plist")
        if FileManager.default.fileExists(atPath: metadata.path) {
            let settings = try PropertyListDecoder().decode(BottleSettings.self, from: Data(contentsOf: metadata))
            additional += PinnedLibrarySource.items(inBottleAt: bottle, settings: settings)
        }
    }
    #else
    if let bottle, let data = try? Data(contentsOf: bottle.appendingPathComponent("Metadata.plist")) {
        let metadata = try PropertyListDecoder().decode(PortableBottleMetadata.self, from: data)
        additional += (metadata.info?.pins ?? []).compactMap { pin in
            guard let url = pin.url else { return nil }
            return LibraryEntry(
                id: "pinned:\(url.path)",
                name: pin.name,
                iconURL: url,
                bottleURL: bottle,
                source: .pinned,
                launch: .program(url),
                launcher: LauncherType.detect(from: url)
            )
        }
    }
    #endif
    if let bottle {
        additional += SteamLibrarySource.entries(inBottleAt: bottle)
        steamDirectories = SteamLibrary.enumerate(bottleURL: bottle).map(\.installURL)
            + [SteamLibrary.detectInstall(bottleURL: bottle)].compactMap { $0 }
    }
    let discovery = LibraryDiscovery.scan(
        in: container, folders: folders, additionalEntries: additional, excluding: steamDirectories
    )
    return discovery.entries.filter { visibility.includes($0, showHidden: includingHidden) }
}

private struct PortableBottleMetadata: Decodable {
    struct Pin: Decodable { let name: String
        let url: URL?
    }

    struct Info: Decodable { let pins: [Pin]? }
    let info: Info?
}

func makeArtworkProvider() -> any ArtworkProviding {
    #if os(macOS)
    return WorkspaceArtworkProvider(base: IconCache.shared)
    #else
    return WorkspaceArtworkProvider(base: FileArtworkProvider())
    #endif
}

@MainActor
func makeDirectoryPicker() -> (any DirectoryPicking)? {
    #if os(Linux)
    return GtkDirectoryPicker()
    #else
    return nil
    #endif
}
