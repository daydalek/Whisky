//
//  FolderGameLibrary.swift
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
import WhiskyCore

extension FolderGameLibrary {
    /// Reassigns a single folder game from `sourceBottleURL` to `targetBottleURL`,
    /// preserving its chosen executable, pending metadata status, and per-program settings.
    public static func moveFolder(
        _ folder: URL,
        from sourceBottleURL: URL,
        to targetBottleURL: URL
    ) throws {
        guard sourceBottleURL.standardizedFileURL != targetBottleURL.standardizedFileURL else { return }
        var sourceLib = try load(bottleURL: sourceBottleURL)
        var targetLib = try load(bottleURL: targetBottleURL)

        let canonicalFolder = folder.standardizedFileURL
        let sourceKey = key(for: canonicalFolder, bottleURL: sourceBottleURL)
        let targetKey = key(for: canonicalFolder, bottleURL: targetBottleURL)
        let parentPath = canonicalFolder.deletingLastPathComponent().path

        let isUnderSourceRoot = sourceLib.roots.contains {
            url(for: $0, bottleURL: sourceBottleURL).standardizedFileURL.path == parentPath
        }
        sourceLib.assignedFolders.removeAll {
            url(for: $0, bottleURL: sourceBottleURL).standardizedFileURL == canonicalFolder
        }
        if isUnderSourceRoot {
            sourceLib.excludedFolders.insert(sourceKey)
        }
        sourceLib.knownFolders.removeAll {
            url(for: $0, bottleURL: sourceBottleURL).standardizedFileURL == canonicalFolder
        }
        let wasPending = sourceLib.pendingMetadata.remove(sourceKey) != nil

        if let exeURL = sourceLib.executable(for: canonicalFolder, bottleURL: sourceBottleURL) {
            targetLib.executables[targetKey] = key(for: exeURL, bottleURL: targetBottleURL)
            migrateProgramSettings(for: exeURL, from: sourceBottleURL, to: targetBottleURL)
        }
        sourceLib.executables.removeValue(forKey: sourceKey)

        targetLib.excludedFolders = targetLib.excludedFolders.filter {
            url(for: $0, bottleURL: targetBottleURL).standardizedFileURL != canonicalFolder
        }
        let isUnderTargetRoot = targetLib.roots.contains {
            url(for: $0, bottleURL: targetBottleURL).standardizedFileURL.path == parentPath
        }
        if !isUnderTargetRoot, !targetLib.assignedFolders.contains(targetKey) {
            targetLib.assignedFolders.append(targetKey)
        }
        if !targetLib.knownFolders.contains(targetKey) {
            targetLib.knownFolders.append(targetKey)
            targetLib.knownFolders.sort()
        }
        if wasPending, targetLib.automaticMetadata {
            targetLib.pendingMetadata.insert(targetKey)
        }

        try targetLib.save(bottleURL: targetBottleURL)
        try sourceLib.save(bottleURL: sourceBottleURL)

        var targetVisibility = try LibraryVisibility.load(bottleURL: targetBottleURL)
        if targetVisibility.hiddenIdentities.remove("program:" + targetKey) != nil {
            try targetVisibility.save(bottleURL: targetBottleURL)
        }
    }

    /// Moves an entire scanned root folder and its discovered games from `sourceBottleURL` to `targetBottleURL`.
    public static func moveRoot( // swiftlint:disable:this function_body_length
        _ rootKey: String,
        from sourceBottleURL: URL,
        to targetBottleURL: URL
    ) async throws {
        guard sourceBottleURL.standardizedFileURL != targetBottleURL.standardizedFileURL else { return }
        var sourceLib = try load(bottleURL: sourceBottleURL)
        var targetLib = try load(bottleURL: targetBottleURL)

        let rootURL = url(for: rootKey, bottleURL: sourceBottleURL).standardizedFileURL
        let targetRootKey = key(for: rootURL, bottleURL: targetBottleURL)

        sourceLib.roots.removeAll {
            url(for: $0, bottleURL: sourceBottleURL).standardizedFileURL == rootURL
        }
        let wasInitialized = sourceLib.initializedRoots.remove(rootKey) != nil
        if !targetLib.roots.contains(targetRootKey) {
            targetLib.roots.append(targetRootKey)
        }
        if wasInitialized {
            targetLib.initializedRoots.insert(targetRootKey)
        }

        let exclusions = sourceLib.excludedFolders.filter {
            url(for: $0, bottleURL: sourceBottleURL).deletingLastPathComponent().standardizedFileURL == rootURL
        }
        sourceLib.excludedFolders.subtract(exclusions)
        targetLib.excludedFolders.formUnion(exclusions.map {
            key(for: url(for: $0, bottleURL: sourceBottleURL), bottleURL: targetBottleURL)
        })

        let sourceStore = GameMetadataStore(directory: sourceBottleURL.appendingPathComponent("Game Metadata"))
        let targetStore = GameMetadataStore(directory: targetBottleURL.appendingPathComponent("Game Metadata"))

        let matchingSourceKeys = sourceLib.knownFolders.filter {
            url(for: $0, bottleURL: sourceBottleURL).deletingLastPathComponent().standardizedFileURL == rootURL
        }
        var targetVisibility = try LibraryVisibility.load(bottleURL: targetBottleURL)
        var visibilityChanged = false
        for folderKey in matchingSourceKeys {
            let folderURL = url(for: folderKey, bottleURL: sourceBottleURL).standardizedFileURL
            let newFolderKey = key(for: folderURL, bottleURL: targetBottleURL)
            try await sourceStore.copyEntry(
                for: "program:" + folderKey, to: targetStore, targetIdentity: "program:" + newFolderKey
            )
            sourceLib.knownFolders.removeAll { $0 == folderKey }
            if !targetLib.knownFolders.contains(newFolderKey) {
                targetLib.knownFolders.append(newFolderKey)
            }
            if targetVisibility.hiddenIdentities.remove("program:" + newFolderKey) != nil {
                visibilityChanged = true
            }
            if sourceLib.pendingMetadata.remove(folderKey) != nil, targetLib.automaticMetadata {
                targetLib.pendingMetadata.insert(newFolderKey)
            }
            if let exeURL = sourceLib.executable(for: folderURL, bottleURL: sourceBottleURL) {
                targetLib.executables[newFolderKey] = key(for: exeURL, bottleURL: targetBottleURL)
                migrateProgramSettings(for: exeURL, from: sourceBottleURL, to: targetBottleURL)
                sourceLib.executables.removeValue(forKey: folderKey)
            }
        }
        targetLib.knownFolders.sort()

        try targetLib.save(bottleURL: targetBottleURL)
        try sourceLib.save(bottleURL: sourceBottleURL)
        if visibilityChanged {
            try targetVisibility.save(bottleURL: targetBottleURL)
        }
    }

    public static func migrateProgramSettings(
        for executableURL: URL,
        from sourceBottleURL: URL,
        to targetBottleURL: URL
    ) {
        SettingsPersistence.shared.flush()
        let fileManager = FileManager.default
        let sourceLocations = Program.settingsLocations(
            for: executableURL, bottleURL: sourceBottleURL, legacyName: executableURL.lastPathComponent
        )
        let targetLocations = Program.settingsLocations(
            for: executableURL, bottleURL: targetBottleURL, legacyName: executableURL.lastPathComponent
        )
        let sourceFile: URL? = if fileManager.fileExists(atPath: sourceLocations.identity.path(percentEncoded: false)) {
            sourceLocations.identity
        } else if fileManager.fileExists(atPath: sourceLocations.legacy.path(percentEncoded: false)) {
            sourceLocations.legacy
        } else {
            nil
        }
        guard let sourceFile,
              !fileManager.fileExists(atPath: targetLocations.identity.path(percentEncoded: false))
        else { return }
        try? fileManager.createDirectory(
            at: targetLocations.identity.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? fileManager.copyItem(at: sourceFile, to: targetLocations.identity)
    }
}
