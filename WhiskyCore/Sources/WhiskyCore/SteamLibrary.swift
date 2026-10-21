//
//  SteamLibrary.swift
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

/// A fully installed Steam game discovered inside a Wine bottle.
public struct SteamGame: Identifiable, Equatable, Sendable {
    public var id: Int {
        appId
    }

    /// The Steam App ID.
    public let appId: Int
    /// The display name from the manifest.
    public let name: String
    /// The resolved absolute URL of the game's install directory.
    public let installURL: URL
    /// The full parsed manifest.
    public let manifest: SteamAppManifest
}

/// Discovers a Windows Steam installation inside a Wine bottle and
/// enumerates its installed games across all configured library folders.
public enum SteamLibrary {
    /// Candidate Steam install locations under `drive_c`.
    private static let installCandidates = [
        "Program Files (x86)/Steam",
        "Program Files/Steam"
    ]

    /// App IDs Steam installs as shared runtime payloads rather than games.
    /// They appear as ordinary manifests but have nothing to launch.
    static let nonGameAppIds: Set<Int> = [
        228_980, // Steamworks Common Redistributables
        1_070_560, // Steam Linux Runtime 1.0 (soldier)
        1_391_110, // Steam Linux Runtime 2.0 (soldier)
        1_628_350 // Steam Linux Runtime 3.0 (sniper)
    ]

    /// Locates the Steam installation inside a bottle.
    ///
    /// - Parameter bottleURL: The root URL of the Wine bottle.
    /// - Returns: The Steam root directory (the one containing `steam.exe`),
    ///   or `nil` if no install is found.
    public static func detectInstall(bottleURL: URL) -> URL? {
        for candidate in installCandidates {
            let root = bottleURL.appending(path: "drive_c").appending(path: candidate)
            let steamExe = root.appending(path: "steam.exe")
            if FileManager.default.fileExists(atPath: steamExe.path(percentEncoded: false)) {
                return root
            }
        }
        return nil
    }

    /// Enumerates fully installed games across every Steam library in the bottle.
    ///
    /// Reads `libraryfolders.vdf` for configured library locations (mapping
    /// Windows paths through the prefix), scans each library's
    /// `steamapps/appmanifest_*.acf`, keeps fully installed games whose
    /// install directory actually exists, and de-duplicates by App ID.
    ///
    /// - Parameter bottleURL: The root URL of the Wine bottle.
    /// - Returns: Installed games sorted by name, empty if Steam isn't installed.
    public static func enumerate(bottleURL: URL) -> [SteamGame] {
        guard let steamRoot = detectInstall(bottleURL: bottleURL) else { return [] }

        let roots = libraryRoots(steamRoot: steamRoot, bottleURL: bottleURL)
        let revision = revision(of: roots)
        if let cached = cache.games(forBottleAt: bottleURL, revision: revision) {
            return cached
        }

        var byAppId: [Int: SteamGame] = [:]
        for library in roots {
            for game in games(inLibrary: library) where byAppId[game.appId] == nil {
                byAppId[game.appId] = game
            }
        }

        let sorted = byAppId.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        cache.store(sorted, forBottleAt: bottleURL, revision: revision)
        return sorted
    }

    /// A stamp that changes whenever a library's contents could have.
    ///
    /// The modification date of each `steamapps` directory, which moves when a
    /// manifest is added or removed, so installing, uninstalling or moving a
    /// game invalidates it. Merely playing one does not, which is the point: a
    /// refresh that changed nothing costs a handful of `stat` calls instead of
    /// parsing every manifest in every library.
    private static func revision(of libraries: [URL]) -> [String] {
        libraries.map { library in
            let steamapps = library.appending(path: "steamapps")
            let modified = try? steamapps.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            let resolvedPath = steamapps.resolvingSymlinksInPath().path(percentEncoded: false)
            return "\(resolvedPath)@\(modified?.timeIntervalSince1970 ?? 0)"
        }
    }

    private static let cache = EnumerationCache()

    /// Remembers the last enumeration per bottle, valid while its libraries
    /// have not been written to.
    private final class EnumerationCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [URL: (revision: [String], games: [SteamGame])] = [:]

        func games(forBottleAt url: URL, revision: [String]) -> [SteamGame]? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries[url], entry.revision == revision else { return nil }
            return entry.games
        }

        func store(_ games: [SteamGame], forBottleAt url: URL, revision: [String]) {
            lock.lock()
            defer { lock.unlock() }
            entries[url] = (revision, games)
        }
    }

    private static let libraryPathsCache = LibraryPathsCache()

    private struct LibraryFileStamp: Equatable {
        let modified: Date
        let size: UInt64
        let inode: UInt64
    }

    /// Caches VDF contents while drive mappings and mounted volumes remain live inputs.
    private final class LibraryPathsCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [URL: (stamp: LibraryFileStamp, paths: [String])] = [:]

        func paths(in url: URL) -> [String] {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date,
                  let size = attributes[.size] as? UInt64,
                  let inode = attributes[.systemFileNumber] as? UInt64
            else { return [] }
            let stamp = LibraryFileStamp(modified: modified, size: size, inode: inode)
            lock.lock()
            let cached = entries[url]
            lock.unlock()
            if let cached, cached.stamp == stamp {
                return cached.paths
            }
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let root = try? VDFParser.parse(text),
                  let folders = root["libraryfolders"]?.objectValue
            else { return [] }
            let paths = folders.values.compactMap { $0.objectValue?["path"]?.stringValue }
            lock.lock()
            entries[url] = (stamp, paths)
            lock.unlock()
            return paths
        }
    }

    /// The Steam root plus each currently accessible configured library.
    /// VDF parsing is cached; existence checks and drive symlinks are resolved on every call.
    public static func libraryRoots(steamRoot: URL, bottleURL: URL) -> [URL] {
        let vdfCandidates = [
            steamRoot.appending(path: "config/libraryfolders.vdf"),
            steamRoot.appending(path: "steamapps/libraryfolders.vdf")
        ]
        var roots = [steamRoot]
        var seen = Set([steamRoot.resolvingSymlinksInPath().standardizedFileURL.path])
        for vdfURL in vdfCandidates {
            for windowsPath in libraryPathsCache.paths(in: vdfURL) {
                guard let mapped = mapWindowsPath(windowsPath, bottleURL: bottleURL) else { continue }
                let resolved = mapped.resolvingSymlinksInPath().standardizedFileURL.path
                var isDirectory: ObjCBool = false
                if !seen.contains(resolved),
                   FileManager.default.fileExists(atPath: mapped.path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    seen.insert(resolved)
                    roots.append(mapped)
                }
            }
        }
        return roots
    }

    /// Discovers library roots for a bottle by first locating its Steam install.
    public static func libraryRoots(bottleURL: URL) -> [URL] {
        guard let steamRoot = detectInstall(bottleURL: bottleURL) else { return [] }
        return libraryRoots(steamRoot: steamRoot, bottleURL: bottleURL)
    }

    /// Whether `component` is a plain name safe to join onto a trusted root.
    ///
    /// Manifest and VDF contents are not trusted input (spoofed
    /// `appmanifest_*.acf` files are common in the repack ecosystem) and
    /// `URL.appending(path:)` does not collapse `..`, so an unchecked component
    /// escapes the library and reaches the games list, the running-state
    /// matcher, and the executable set handed to taskkill.
    public static func isSafePathComponent(_ component: String) -> Bool {
        guard !component.isEmpty, component != ".", component != ".." else { return false }
        return !component.contains("/") && !component.contains("\\") && !component.contains("\0")
    }

    /// Maps a Windows path from a VDF file (`D:\\SteamLibrary`) to its
    /// location inside the prefix: `drive_c` for the C drive, the
    /// `dosdevices/<letter>:` symlink for everything else.
    ///
    /// Returns `nil` when any component would escape the prefix.
    public static func mapWindowsPath(_ windowsPath: String, bottleURL: URL) -> URL? {
        let normalized = windowsPath.replacingOccurrences(of: "\\", with: "/")
        guard normalized.count >= 2 else { return nil }

        let driveLetter = normalized.prefix(1).lowercased()
        guard normalized[normalized.index(normalized.startIndex, offsetBy: 1)] == ":",
              driveLetter.first?.isLetter == true
        else { return nil }

        let rest = String(normalized.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = rest.split(separator: "/").map(String.init)
        guard components.allSatisfy(isSafePathComponent) else { return nil }

        let base: URL = if driveLetter == "c" {
            bottleURL.appending(path: "drive_c")
        } else {
            bottleURL.appending(path: "dosdevices").appending(path: "\(driveLetter):")
        }

        return components.reduce(base) { $0.appending(path: $1) }
    }

    /// Fully installed games in one library root whose install directory exists.
    private static func games(inLibrary library: URL) -> [SteamGame] {
        let steamApps = library.appending(path: "steamapps")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            atPath: steamApps.path(percentEncoded: false)
        )
        else { return [] }

        var found: [SteamGame] = []
        for filename in contents where filename.hasPrefix("appmanifest_") && filename.hasSuffix(".acf") {
            guard let manifest = SteamAppManifest(contentsOf: steamApps.appending(path: filename)),
                  manifest.isFullyInstalled,
                  isSafePathComponent(manifest.installDir),
                  !nonGameAppIds.contains(manifest.appId)
            else { continue }

            let installURL = steamApps.appending(path: "common").appending(path: manifest.installDir)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: installURL.path(percentEncoded: false), isDirectory: &isDirectory
            ), isDirectory.boolValue
            else { continue }

            found.append(SteamGame(
                appId: manifest.appId,
                name: manifest.name,
                installURL: installURL,
                manifest: manifest
            ))
        }
        return found
    }

    /// Executables at the install root and one directory deep.
    public static func executableURLs(under installURL: URL) -> [URL] {
        let fileManager = FileManager.default
        var executables: [URL] = []
        var subdirectories: [URL] = []

        let top = (try? fileManager.contentsOfDirectory(
            at: installURL, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        for item in top {
            if item.pathExtension.lowercased() == "exe" {
                executables.append(item)
            } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                subdirectories.append(item)
            }
        }
        for directory in subdirectories {
            let items = (try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )) ?? []
            executables.append(contentsOf: items.filter { $0.pathExtension.lowercased() == "exe" })
        }
        return executables
    }

    /// Lowercased executable names at the install root and one directory
    /// deep, plus any user-selected program binary. Used to match a game's processes in the bottle's task list.
    public static func executableNames(under installURL: URL, selectedURL: URL? = nil) -> Set<String> {
        var names = Set(executableURLs(under: installURL).map { $0.lastPathComponent.lowercased() })
        if let selected = selectedURL {
            names.insert(selected.lastPathComponent.lowercased())
        }
        return names
    }
}
