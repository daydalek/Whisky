//
//  DistributionConfig.swift
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

public enum DistributionConfig {
    /// Base URL for GitHub Pages distribution
    public static let baseURL = "https://frankea.github.io/Whisky"

    /// Public static manifest maintained by the Wine release CI.
    public static let versionPlistURL =
        "https://raw.githubusercontent.com/daydalek/ge-proton-macos-wine-poc/runtime-channel/WhiskyWineVersion.plist"

    /// GE-patched macOS Wine releases used by this fork.
    public static let wineRepository = "daydalek/ge-proton-macos-wine-poc"

    /// Base URL for the Wine runtime assets.
    public static let releasesBaseURL = "https://github.com/\(wineRepository)/releases/download"

    /// URL for the Sparkle appcast feed
    public static let appcastURL = "\(baseURL)/appcast.xml"

    /// Constructs the download URL for Wine Libraries from GitHub Releases
    /// - Parameter version: The version string (e.g., "2.5.0")
    /// - Returns: The full URL to download Libraries.tar.gz from GitHub Releases
    public static func librariesURL(version: String) -> String {
        "\(releasesBaseURL)/v\(version)/Libraries.tar.gz"
    }

    public enum WineManifestError: LocalizedError, Equatable {
        case invalidManifest
        case httpStatus(Int)

        public var errorDescription: String? {
            switch self {
            case .invalidManifest:
                "The Wine version manifest has an invalid archive URL or SHA-256."
            case .httpStatus(let status):
                "Wine version manifest download returned HTTP \(status)."
            }
        }
    }

    private static let manifestCache = WineManifestCache()

    /// Normal checks share a one-hour cache. Setup and explicit retries fetch fresh metadata.
    public static func fetchWineManifest(
        session: URLSession = .shared, useCache: Bool = true
    ) async throws -> WhiskyWineVersion {
        let data = try await manifestCache.fetch(session: session, useCache: useCache)
        return try PropertyListDecoder().decode(WhiskyWineVersion.self, from: data)
    }

    public static func librariesURL(for manifest: WhiskyWineVersion) throws -> URL {
        let value = manifest.downloadURL ?? librariesURL(version: manifest.version.description)
        guard let url = URL(string: value), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.query == nil,
              url.path.hasPrefix("/\(wineRepository)/releases/download/"),
              url.lastPathComponent == "Libraries.tar.gz" else { throw WineManifestError.invalidManifest }
        return url
    }
}

private actor WineManifestCache {
    private var data: Data?
    private var checkedAt: Date?

    func fetch(session: URLSession, useCache: Bool) async throws -> Data {
        if useCache, let data, let checkedAt, Date().timeIntervalSince(checkedAt) < 3600 {
            return data
        }
        var request = URLRequest(url: URL(string: DistributionConfig.versionPlistURL)!)
        request.cachePolicy = .reloadRevalidatingCacheData
        request.timeoutInterval = 30
        let (fresh, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DistributionConfig.WineManifestError.httpStatus(http.statusCode)
        }
        let manifest = try PropertyListDecoder().decode(WhiskyWineVersion.self, from: fresh)
        _ = try DistributionConfig.librariesURL(for: manifest)
        guard manifest.sha256 != nil else { throw DistributionConfig.WineManifestError.invalidManifest }
        data = fresh
        checkedAt = Date()
        return fresh
    }
}
