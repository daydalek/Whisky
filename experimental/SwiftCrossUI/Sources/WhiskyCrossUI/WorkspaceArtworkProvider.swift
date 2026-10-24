//
//  WorkspaceArtworkProvider.swift
//  WhiskyCrossUI
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
import WhiskyCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Uses the same cover cache layout as the production metadata store.
actor WorkspaceArtworkProvider: ArtworkProviding {
    private let base: any ArtworkProviding
    private let session: URLSession

    init(base: any ArtworkProviding, session: URLSession = .shared) {
        self.base = base
        self.session = session
    }

    func artwork(for request: ArtworkRequest) async -> ArtworkAsset? {
        guard case let .image(url) = request.source, !url.isFileURL else {
            return await base.artwork(for: request)
        }
        guard url.scheme == "https", let directory = request.cacheDirectory else { return nil }
        let cached = LibraryStorageLayout.cachedCover(url, directory: directory)
        if FileManager.default.fileExists(atPath: cached.path) {
            return await base.artwork(for: ArtworkRequest(source: .image(cached), maxPixelSize: request.maxPixelSize))
        }
        let preferences = UserDefaults(suiteName: "com.franke.Whisky") ?? .standard
        guard !preferences.bool(forKey: "offlineMode"), !Task.isCancelled else { return nil }
        do {
            var download = URLRequest(url: url, timeoutInterval: 20)
            download.setValue("Whisky/1.0 (game metadata)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: download)
            guard let response = response as? HTTPURLResponse, (200 ..< 300).contains(response.statusCode),
                  response.mimeType?.hasPrefix("image/") == true,
                  ArtworkAsset(data: data).isWithinDecodingBudget, !Task.isCancelled
            else { return nil }
            try FileManager.default.createDirectory(
                at: cached.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: cached, options: .atomic)
            return await base.artwork(for: ArtworkRequest(source: .image(cached), maxPixelSize: request.maxPixelSize))
        } catch { return nil }
    }
}
