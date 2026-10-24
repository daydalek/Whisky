//
//  ExecutablePicker.swift
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

/// A frontend supplies its native file dialog at the composition root.
@MainActor
public protocol ExecutablePicker {
    func chooseExecutable(in directory: URL) async -> URL?
}

@MainActor
public struct ClosureExecutablePicker: ExecutablePicker {
    private let choose: @MainActor (URL) async -> URL?

    public init(_ choose: @escaping @MainActor (URL) async -> URL?) {
        self.choose = choose
    }

    public func chooseExecutable(in directory: URL) async -> URL? {
        await choose(directory)
    }
}

public enum ExecutableSelectionError: Error {
    case requiresExecutableFile
}

/// Recursive discovery of the executables a folder game could be started from.
///
/// A folder holds a whole installed game: the launcher is usually nested, so
/// the search cannot stop at the top level the way `SteamLibrary` does.
public enum ExecutableCandidateFinder {
    /// Only `.exe` is a launch target.
    ///
    /// `folders.executable` rejects anything else, so a script the game ships
    /// (`.bat`, `.cmd`, `.ps1`, `.vbs`, `.js`), a `.lnk` shortcut and an
    /// `.msi` installer would be refused after the user picked them. Keeping
    /// them out of the list is what makes it worth reading.
    public static func isCandidate(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "exe"
    }

    /// `.exe` files under `folder`, deepest directory first.
    ///
    /// Symlinks are skipped so a link back to an ancestor cannot loop, and a
    /// bundle is not descended into because its executables are not the game.
    /// `maxDepth` and `limit` bound the walk: an install directory can hold
    /// tens of thousands of files.
    public static func candidates(
        in folder: URL,
        maxDepth: Int = 6,
        limit: Int = 200
    ) -> [URL] {
        let fileManager = FileManager.default
        var found: [URL] = []
        var directories: [(url: URL, depth: Int)] = [(folder, 0)]
        while let directory = directories.popLast(), found.count < limit {
            guard let items = try? fileManager.contentsOfDirectory(
                at: directory.url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey],
                options: [.skipsHiddenFiles]
            )
            else { continue }
            var deeper: [URL] = []
            for item in items {
                let values = try? item.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
                )
                guard values?.isSymbolicLink != true else { continue }
                if values?.isDirectory == true {
                    if directory.depth + 1 < maxDepth, values?.isPackage != true {
                        deeper.append(item)
                    }
                    continue
                }
                guard isCandidate(item) else { continue }
                found.append(item)
                guard found.count < limit else { break }
            }
            directories.append(contentsOf: deeper.map { ($0, directory.depth + 1) })
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

@MainActor
extension FolderGameLibrary {
    /// Selection is asynchronous so each toolkit can use its native dialog lifecycle.
    public static func resolveExecutable(
        for entry: LibraryEntry, chooseAgain: Bool = false, picker: any ExecutablePicker
    ) async throws -> URL? {
        guard case let .program(folder) = entry.launch else { return nil }
        let library = try load(bottleURL: entry.bottleURL)
        if !chooseAgain, let cached = library.executable(for: folder, bottleURL: entry.bottleURL),
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        guard let selected = await picker.chooseExecutable(in: folder) else { return nil }
        try Task.checkCancellation()
        guard selected.pathExtension.lowercased() == "exe",
              try (selected.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true
        else { throw ExecutableSelectionError.requiresExecutableFile }
        // The dialog may suspend while another action updates this library.
        var current = try load(bottleURL: entry.bottleURL)
        current.executables[key(for: folder, bottleURL: entry.bottleURL)] = key(
            for: selected, bottleURL: entry.bottleURL
        )
        try current.save(bottleURL: entry.bottleURL)
        return selected
    }
}
