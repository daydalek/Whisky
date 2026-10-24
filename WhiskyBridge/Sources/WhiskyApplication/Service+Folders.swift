//
//  Service+Folders.swift
//  WhiskyApplication
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
import WhiskyCore

// MARK: - Folder game library methods

extension ApplicationService {
    func foldersCall(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
        let container = try workspace.resolve(params)
        switch method {
        case "folders.read":
            let library = try FolderGameLibrary.load(bottleURL: container)
            return try Self.encodeFolders(library, container: container)
        case "folders.addRoot":
            let target = try Self.validatedDirectory(try params.path("path"))
            return try addRoots([target], container: container)
        case "folders.addRoots":
            guard case let .array(items)? = params["paths"] else {
                throw BridgeFailure("invalid_params", "Expected path strings: paths")
            }
            let targets = try items.map { item -> URL in
                guard let text = item.string, text.hasPrefix("/") else {
                    throw BridgeFailure("invalid_params", "Expected absolute path strings: paths")
                }
                return try Self.validatedDirectory(URL(fileURLWithPath: text).standardizedFileURL)
            }
            return try addRoots(targets, container: container)
        case "folders.automaticMetadata":
            let enabled = try params.flag("enabled")
            return try Self.mutateFolders(in: container) { library in
                library.automaticMetadata = enabled
            }
        case "folders.visibility":
            let included = try params.flag("included")
            let lockURL = container.appendingPathComponent("Library Visibility.json.lock")
            try HostFileLock().withExclusiveLock(at: lockURL) {
                var visibility = try LibraryVisibility.load(bottleURL: container)
                visibility.includePinnedAndSteam = included
                try visibility.save(bottleURL: container)
            }
            return try Self.encodeFolders(
                try FolderGameLibrary.load(bottleURL: container),
                container: container
            )
        case "folders.removeRoot":
            let key = FolderGameLibrary.key(for: try params.path("path"), bottleURL: container)
            return try Self.mutateFolders(in: container) { library in
                library.roots.removeAll { $0 == key }
                library.initializedRoots.remove(key)
            }
        case "folders.assign":
            return try assignFolder(params, container: container)
        case "folders.exclude":
            let key = FolderGameLibrary.key(for: try params.path("path"), bottleURL: container)
            let excluded = try params.flag("excluded")
            return try Self.mutateFolders(in: container) { library in
                if excluded {
                    library.excludedFolders.insert(key)
                } else {
                    library.excludedFolders.remove(key)
                }
            }
        case "folders.executable":
            return try setFolderExecutable(params, container: container)
        case "folders.candidates":
            return try folderCandidates(params, container: container)
        default:
            return try await nativeCall(method, params: params)
        }
    }

    /// Adding a root mirrors the SwiftUI sheet: it also drops exclusions that
    /// targeted that root's parent and unhides any games discovered under it,
    /// so a freshly added folder is immediately visible.
    private func addRoots(_ targets: [URL], container: URL) throws -> JSONValue {
        var keys: [String] = []
        let updated = try Self.mutateFolders(in: container) { library in
            for target in targets {
                let key = FolderGameLibrary.key(for: target, bottleURL: container)
                keys.append(key)
                if !library.roots.contains(key) {
                    library.roots.append(key)
                }
                let rootPath = target.standardizedFileURL.path
                library.excludedFolders = library.excludedFolders.filter { excludedKey in
                    FolderGameLibrary.url(for: excludedKey, bottleURL: container)
                        .deletingLastPathComponent().standardizedFileURL.path != rootPath
                }
            }
        }
        var visibility = try LibraryVisibility.load(bottleURL: container)
        var changed = false
        for key in keys {
            let trimmed = key.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let prefixes = ["program:" + trimmed + "/", "program:" + key + "/"]
            let before = visibility.hiddenIdentities.count
            visibility.hiddenIdentities = visibility.hiddenIdentities.filter { identity in
                !prefixes.contains { identity.hasPrefix($0) }
            }
            changed = changed || visibility.hiddenIdentities.count != before
        }
        if changed {
            try visibility.save(bottleURL: container)
        }
        return updated
    }

    private func assignFolder(_ params: [String: JSONValue], container: URL) throws -> JSONValue {
        let folder = try params.path("path")
        let assigned = params["assigned"] == nil ? true : try params.flag("assigned")
        if assigned {
            _ = try Self.validatedDirectory(folder)
        }
        let key = FolderGameLibrary.key(for: folder, bottleURL: container)
        return try Self.mutateFolders(in: container) { library in
            library.assignedFolders.removeAll { $0 == key }
            if assigned {
                library.assignedFolders.append(key)
            }
        }
    }

    private func setFolderExecutable(_ params: [String: JSONValue], container: URL) throws -> JSONValue {
        var folder = try params.path("path")
        if let values = try? folder.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory != true {
            folder = folder.deletingLastPathComponent()
        }
        _ = try Self.validatedDirectory(folder)
        let folderKey = FolderGameLibrary.key(for: folder, bottleURL: container)
        let executableKey: String?
        switch params["executable"] {
        case .null:
            executableKey = nil
        case .some:
            let executable = try params.path("executable")
            guard executable.pathExtension.lowercased() == "exe",
                  (try? executable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else {
                throw BridgeFailure("invalid_params", "Expected an existing .exe file: executable")
            }
            executableKey = FolderGameLibrary.key(for: executable, bottleURL: container)
        case nil:
            throw BridgeFailure("invalid_params", "Expected path string or null: executable")
        }
        return try Self.mutateFolders(in: container) { library in
            library.executables[folderKey] = executableKey
        }
    }

    /// Every `.exe` under a folder, for a frontend that offers its own picker
    /// instead of a platform file dialog.
    private func folderCandidates(_ params: [String: JSONValue], container: URL) throws -> JSONValue {
        var folder = try params.path("path")
        if let values = try? folder.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory != true {
            folder = folder.deletingLastPathComponent()
        }
        folder = try Self.validatedDirectory(folder)
        let found = ExecutableCandidateFinder.candidates(in: folder)
        return .object([
            "folder": .string(folder.path),
            "candidates": .array(found.map {
                .object(["path": .string($0.path), "name": .string($0.lastPathComponent)])
            })
        ])
    }

    private static func validatedDirectory(_ url: URL) throws -> URL {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true
        else {
            throw BridgeFailure("invalid_params", "Expected a non-symlink directory path")
        }
        return url
    }

    private static func mutateFolders(
        in container: URL,
        operation: (inout FolderGameLibrary) throws -> Void
    ) throws -> JSONValue {
        let lockURL = container.appendingPathComponent("Folder Games.json.lock")
        let updated = try HostFileLock().withExclusiveLock(at: lockURL) {
            var library = try FolderGameLibrary.load(bottleURL: container)
            try operation(&library)
            try library.save(bottleURL: container)
            return library
        }
        return try encodeFolders(updated, container: container)
    }

    private static func encodeFolders(_ library: FolderGameLibrary, container: URL) throws -> JSONValue {
        let resolve = { (key: String) in FolderGameLibrary.url(for: key, bottleURL: container).path }
        let executables = Dictionary(uniqueKeysWithValues: library.executables.map { key, value in
            (resolve(key), JSONValue.string(resolve(value)))
        })
        let visibility = try LibraryVisibility.load(bottleURL: container)
        return .object([
            "roots": .array(library.roots.map { .string(resolve($0)) }),
            "assignedFolders": .array(library.assignedFolders.map { .string(resolve($0)) }),
            "excludedFolders": .array(library.excludedFolders.sorted().map { .string(resolve($0)) }),
            "executables": .object(executables),
            "knownFolders": .array(library.knownFolders.map { .string(resolve($0)) }),
            "automaticMetadata": .bool(library.automaticMetadata),
            "includePinnedAndSteam": .bool(visibility.includePinnedAndSteam)
        ])
    }
}
