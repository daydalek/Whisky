//
//  ProgramStorageLayout.swift
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

public enum ProgramStorageLayout {
    public static func identity(for url: URL, containerURL: URL) -> String {
        let root = containerURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let relative = path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
        return "\(url.deletingPathExtension().lastPathComponent)-\(LibraryStorageLayout.key(relative).prefix(8))"
    }

    public static func locations(for url: URL, containerURL: URL) -> (identity: URL, legacy: URL) {
        let directory = containerURL.appendingPathComponent("Program Settings")
        return (
            directory.appendingPathComponent(identity(for: url, containerURL: containerURL))
                .appendingPathExtension("plist"),
            directory.appendingPathComponent(url.lastPathComponent).appendingPathExtension("plist")
        )
    }
}
