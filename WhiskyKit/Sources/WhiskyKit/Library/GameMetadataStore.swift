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
import ImageIO

/// Separate from ProgramSettings: attaching or removing artwork cannot change a launch.
/// The caller supplies a bottle-relative identity so moving a bottle preserves metadata.
public actor GameMetadataStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func loadCoverSettings(for identity: String) throws -> GameCoverSettings {
        let url = coverSettingsLocation(for: identity)
        guard FileManager.default.fileExists(atPath: url.path) else { return GameCoverSettings() }
        return try JSONDecoder().decode(GameCoverSettings.self, from: Data(contentsOf: url))
    }

    public func coverAspectRatio(for identity: String, metadataCoverURL: URL?) throws -> Double? {
        let settings = try loadCoverSettings(for: identity)
        let custom = settings.useCustomCover ? customCoverURL(for: settings) : nil
        let url = custom ?? metadataCoverURL.flatMap { cachedCoverURL(for: $0) }
        guard let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0
        else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5 ... 8).contains(orientation) ? height / width : width / height
    }

    public func saveCoverSettings(_ settings: GameCoverSettings, for identity: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: coverSettingsLocation(for: identity), options: .atomic)
    }

    /// Own the imported bytes so the user's original file can move independently.
    public func importCover(_ data: Data, for identity: String) throws -> GameCoverSettings {
        guard data.count <= 30 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var settings = try loadCoverSettings(for: identity)
        let oldURL = customCoverURL(for: settings)
        settings.customFileName = UUID().uuidString
        settings.useCustomCover = true
        let url = directory.appendingPathComponent("Custom Covers", isDirectory: true)
            .appendingPathComponent(settings.customFileName ?? "")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        do {
            try saveCoverSettings(settings, for: identity)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        if let oldURL { try? FileManager.default.removeItem(at: oldURL) }
        return settings
    }

    public nonisolated func customCoverURL(for settings: GameCoverSettings) -> URL? {
        guard let name = settings.customFileName, UUID(uuidString: name) != nil else { return nil }
        let url = directory.appendingPathComponent("Custom Covers", isDirectory: true).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private nonisolated func coverSettingsLocation(for identity: String) -> URL {
        location(for: identity).appendingPathExtension("cover-settings")
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

        if fileManager.fileExists(atPath: coverSettingsLocation(for: sourceIdentity).path),
           !fileManager.fileExists(atPath: targetStore.coverSettingsLocation(for: targetIdentity).path) {
            let settings = try loadCoverSettings(for: sourceIdentity)
            if let sourceCover = customCoverURL(for: settings), let name = settings.customFileName {
                let targetCover = targetStore.directory.appendingPathComponent("Custom Covers", isDirectory: true)
                    .appendingPathComponent(name)
                try fileManager.createDirectory(
                    at: targetCover.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if !fileManager.fileExists(atPath: targetCover.path) {
                    try fileManager.copyItem(at: sourceCover, to: targetCover)
                }
            }
            try await targetStore.saveCoverSettings(settings, for: targetIdentity)
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

/// Presentation choices stay independent of provider snapshots and cache refreshes.
public struct GameCoverSettings: Codable, Equatable, Sendable {
    public var useCustomCover = false
    public var customFileName: String?
    public var zoom: Double = 1
    public var horizontalPosition: Double = 0.5
    public var verticalPosition: Double = 0.5

    public init() {}
}
