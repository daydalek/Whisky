// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

/// Separate from ProgramSettings: attaching or removing artwork cannot change a launch.
/// The caller supplies a bottle-relative identity so moving a bottle preserves metadata.
public actor GameMetadataStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func load(for identity: String) throws -> GameMetadata? {
        let url = location(for: identity)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(GameMetadata.self, from: Data(contentsOf: url))
    }

    public func save(_ metadata: GameMetadata, for identity: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(metadata).write(to: location(for: identity), options: .atomic)
    }

    public func remove(for identity: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: location(for: identity).appendingPathExtension("manual"), options: .atomic)
        let url = location(for: identity)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func allowsAutomaticMatch(for identity: String) throws -> Bool {
        try load(for: identity) == nil
            && !FileManager.default.fileExists(atPath: location(for: identity).appendingPathExtension("manual").path)
    }

    /// Exclusive creation also protects a manual save through another store actor.
    public func saveAutomatic(_ metadata: GameMetadata, for identity: String) throws {
        guard try allowsAutomaticMatch(for: identity) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(metadata).write(to: location(for: identity), options: .withoutOverwriting)
    }

    /// Artwork is keyed by its URL, not by title, so two works cannot overwrite
    /// each other's cover. Keep the remote URL in metadata for provenance.
    public func cachedCoverURL(for url: URL) -> URL? {
        let location = coverLocation(for: url)
        return FileManager.default.fileExists(atPath: location.path) ? location : nil
    }

    public func cacheCover(from url: URL, session: URLSession = .shared) async throws {
        guard cachedCoverURL(for: url) == nil else { return }
        guard url.scheme == "https" else { throw URLError(.unsupportedURL) }
        let request = URLRequest(url: url, timeoutInterval: 20)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              response.mimeType?.hasPrefix("image/") == true,
              !data.isEmpty, data.count <= 15 * 1024 * 1024 else {
            throw URLError(.badServerResponse)
        }
        try Task.checkCancellation()
        let location = coverLocation(for: url)
        try FileManager.default.createDirectory(
            at: location.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: location, options: .atomic)
    }

    private func coverLocation(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("Covers", isDirectory: true).appendingPathComponent(digest)
    }

    private func location(for identity: String) -> URL {
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest).appendingPathExtension("json")
    }
}

extension LibraryEntry {
    public var metadataIdentity: String {
        switch launch {
        case .steam(let appID): return "steam:\(appID)"
        case .program(let url):
            let root = bottleURL.standardizedFileURL.path + "/"
            let path = url.standardizedFileURL.path
            return "program:" + (path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path)
        }
    }

    public var metadataDirectory: URL {
        bottleURL.appendingPathComponent("Game Metadata", isDirectory: true)
    }
}
