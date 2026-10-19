//
//  SteamDownloadSnapshot.swift
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

/// Recursive download metadata, captured off the UI actor by the app monitor.
public struct SteamDownloadSnapshot: Equatable, Sendable {
    private struct Item: Equatable, Sendable {
        let size: Int
        let modified: Date?
    }

    private var items: [String: Item] = [:]

    public var isEmpty: Bool { items.isEmpty }

    /// Reads metadata at every depth so writes into existing nested files count as progress.
    /// A failed or cancelled scan throws; callers can retain the last reliable sample.
    public static func capture(libraryRoots: [URL]) throws -> SteamDownloadSnapshot {
        try Task.checkCancellation()
        var snapshot = SteamDownloadSnapshot()
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        for root in libraryRoots {
            try Task.checkCancellation()
            let directory = root.appending(path: "steamapps/downloading")
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { continue }
            var scanError: Error?
            guard let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles],
                errorHandler: { _, error in
                    scanError = error
                    return false
                }
            )
            else { throw CocoaError(.fileReadUnknown) }
            for case let url as URL in enumerator {
                try Task.checkCancellation()
                let values = try url.resourceValues(forKeys: keys)
                snapshot.items[url.path] = Item(size: values.fileSize ?? 0, modified: values.contentModificationDate)
            }
            if let scanError { throw scanError }
        }
        return snapshot
    }
}
