//
//  SteamGameProgram.swift
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

/// Explicit executable association for a Steam library entry. It does not turn
/// the entry into a pin or bypass the client's launch/DRM path.
public enum SteamGameProgram {
    public static func selectedURL(appID: Int, installURL: URL, bottleURL: URL) throws -> URL? {
        let file = location(appID: appID, bottleURL: bottleURL)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let path = try PropertyListDecoder().decode(Selection.self, from: Data(contentsOf: file)).relativePath
        let url = installURL.appendingPathComponent(path).standardizedFileURL
        guard isContainedExecutable(url, in: installURL),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    public static func select(_ url: URL, appID: Int, installURL: URL, bottleURL: URL) throws {
        guard isContainedExecutable(url, in: installURL) else { throw URLError(.badURL) }
        let root = installURL.standardizedFileURL.path + "/"
        let path = String(url.standardizedFileURL.path.dropFirst(root.count))
        let file = location(appID: appID, bottleURL: bottleURL)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try PropertyListEncoder().encode(Selection(relativePath: path)).write(to: file, options: .atomic)
    }

    private struct Selection: Codable { let relativePath: String }

    public static func clear(appID: Int, bottleURL: URL) throws {
        let file = location(appID: appID, bottleURL: bottleURL)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    private static func isContainedExecutable(_ url: URL, in root: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
            && url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/")
            && url.pathExtension.lowercased() == "exe"
    }

    private static func location(appID: Int, bottleURL: URL) -> URL {
        bottleURL.appendingPathComponent("Steam Game Settings", isDirectory: true)
            .appendingPathComponent("\(appID).plist")
    }
}
