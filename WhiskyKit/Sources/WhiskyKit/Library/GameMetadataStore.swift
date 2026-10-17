//
//  GameMetadataStore.swift
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
        try Data().write(to: manualLocation(for: identity), options: .atomic)
        let url = location(for: identity)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func allowsAutomaticMatch(for identity: String) throws -> Bool {
        try load(for: identity) == nil
            && !FileManager.default.fileExists(atPath: manualLocation(for: identity).path)
    }

    /// Exclusive creation also protects a manual save through another store actor.
    public func saveAutomatic(_ metadata: GameMetadata, for identity: String) throws {
        guard try allowsAutomaticMatch(for: identity) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(metadata).write(to: location(for: identity), options: .withoutOverwriting)
    }

    /// Artwork is keyed by its URL, not by title, so two works cannot overwrite
    /// each other's cover. Keep the remote URL in metadata for provenance.
    public nonisolated func cachedCoverURL(for url: URL) -> URL? {
        let location = coverLocation(for: url)
        return FileManager.default.fileExists(atPath: location.path) ? location : nil
    }

    public func cacheCover(from url: URL, session: URLSession = .shared) async throws {
        guard cachedCoverURL(for: url) == nil else { return }
        guard url.scheme == "https" else { throw URLError(.unsupportedURL) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Whisky/1.0 (game metadata)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode),
              response.mimeType?.hasPrefix("image/") == true,
              !data.isEmpty, data.count <= 15 * 1_024 * 1_024
        else {
            throw URLError(.badServerResponse)
        }
        try Task.checkCancellation()
        let location = coverLocation(for: url)
        try FileManager.default.createDirectory(
            at: location.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: location, options: .atomic)
    }

    /// Copies saved metadata, manual-unlink markers, and cached cover artwork to another bottle's store.
    public func copyEntry(
        for sourceIdentity: String,
        to targetStore: GameMetadataStore,
        targetIdentity: String
    ) async throws {
        let fileManager = FileManager.default
        let sourceManual = manualLocation(for: sourceIdentity)
        let targetManual = targetStore.manualLocation(for: targetIdentity)
        if fileManager.fileExists(atPath: sourceManual.path), !fileManager.fileExists(atPath: targetManual.path) {
            try fileManager.createDirectory(
                at: targetManual.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? fileManager.copyItem(at: sourceManual, to: targetManual)
        }

        if let metadata = try load(for: sourceIdentity) {
            if try await targetStore.load(for: targetIdentity) == nil {
                try await targetStore.save(metadata, for: targetIdentity)
            }
            if let coverURL = metadata.coverURL,
               let sourceCover = cachedCoverURL(for: coverURL),
               targetStore.cachedCoverURL(for: coverURL) == nil {
                let targetCover = targetStore.coverLocation(for: coverURL)
                try fileManager.createDirectory(
                    at: targetCover.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try? fileManager.copyItem(at: sourceCover, to: targetCover)
            }
        }
    }

    public nonisolated func manualLocation(for identity: String) -> URL {
        location(for: identity).appendingPathExtension("manual")
    }

    public nonisolated func coverLocation(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("Covers", isDirectory: true).appendingPathComponent(digest)
    }

    private nonisolated func location(for identity: String) -> URL {
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest).appendingPathExtension("json")
    }
}

extension LibraryEntry {
    public var metadataIdentity: String {
        switch launch {
        case let .steam(appID): return "steam:\(appID)"
        case let .program(url):
            let root = bottleURL.standardizedFileURL.path + "/"
            let path = url.standardizedFileURL.path
            return "program:" + (path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path)
        }
    }

    public var metadataDirectory: URL {
        bottleURL.appendingPathComponent("Game Metadata", isDirectory: true)
    }
}
