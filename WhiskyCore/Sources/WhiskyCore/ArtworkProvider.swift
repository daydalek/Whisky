//
//  ArtworkProvider.swift
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

public enum ArtworkSource: Hashable, Sendable {
    case image(URL)
    case executable(URL)
    public var url: URL {
        switch self {
        case let .image(url), let .executable(url): url
        }
    }
}

public struct ArtworkRequest: Hashable, Sendable {
    public let source: ArtworkSource
    public let maxPixelSize: Int
    public let cacheDirectory: URL?
    public init(source: ArtworkSource, maxPixelSize: Int = 128, cacheDirectory: URL? = nil) {
        self.source = source
        self.maxPixelSize = min(max(maxPixelSize, 1), 1_024)
        self.cacheDirectory = cacheDirectory
    }
}

/// Encoded image bytes cross the UI boundary; each toolkit owns its decoded image object.
public struct ArtworkAsset: Equatable, Sendable {
    public let data: Data
    public let palette: IconPalette
    public init(data: Data, palette: IconPalette = .neutral) {
        self.data = data
        self.palette = palette
    }

    public var isWithinDecodingBudget: Bool {
        guard data.count <= 16 * 1_024 * 1_024, let dimensions = ArtworkHeader.dimensions(data),
              dimensions.width > 0, dimensions.height > 0,
              dimensions.width <= 8_192, dimensions.height <= 8_192
        else { return false }
        return dimensions.width * dimensions.height <= 4 * 1_024 * 1_024
    }
}

public protocol ArtworkProviding: Sendable {
    func artwork(for request: ArtworkRequest) async -> ArtworkAsset?
}

/// Portable browsing can load existing PNG, JPEG and WebP files with a bounded encoded size.
public actor FileArtworkProvider: ArtworkProviding {
    private let maximumBytes: Int
    public init(maximumBytes: Int = 16 * 1_024 * 1_024) {
        self.maximumBytes = min(max(0, maximumBytes), 16 * 1_024 * 1_024)
    }

    public func artwork(for request: ArtworkRequest) -> ArtworkAsset? {
        guard case let .image(url) = request.source, url.isFileURL, !Task.isCancelled,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size > 0, size <= maximumBytes,
              let file = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: maximumBytes + 1), !data.isEmpty, data.count <= maximumBytes
        else { return nil }
        let asset = ArtworkAsset(data: data)
        guard asset.isWithinDecodingBudget, !Task.isCancelled else { return nil }
        return asset
    }
}

public extension LibraryEntry {
    var artworkSource: ArtworkSource? {
        if let artworkURL {
            return .image(artworkURL)
        }
        guard let iconURL else { return nil }
        return iconURL.pathExtension.lowercased() == "exe" ? .executable(iconURL) : .image(iconURL)
    }
}
