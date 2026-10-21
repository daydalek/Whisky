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
