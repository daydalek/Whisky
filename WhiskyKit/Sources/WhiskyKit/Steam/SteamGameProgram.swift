// SPDX-License-Identifier: GPL-3.0-or-later

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
              FileManager.default.fileExists(atPath: url.path) else { return nil }
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
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
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
