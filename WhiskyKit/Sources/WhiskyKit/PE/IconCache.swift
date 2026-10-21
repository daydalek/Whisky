//
//  IconCache.swift
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

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WhiskyCore

/// Thread-safe cache for program icons extracted from PE files.
///
/// This actor-based cache reduces redundant PE file parsing by storing extracted icons
/// in memory. Icons are expensive to extract as they require parsing the PE resource
/// section and converting bitmap data.
///
/// ## Usage
/// ```swift
/// let icon = await IconCache.shared.iconAsync(for: programURL)
/// ```
public actor IconCache: ArtworkProviding {
    /// The shared icon cache instance.
    public static let shared = IconCache()

    /// A decoded image, a pre-blurred ambient thumbnail, and the palette sampled from it.
    public struct Sampled: Sendable {
        public let image: NSImage
        public let ambient: NSImage
        public let palette: IconPalette

        public init(image: NSImage, ambient: NSImage? = nil, palette: IconPalette) {
            self.image = image
            self.ambient = ambient ?? image
            self.palette = palette
        }
    }

    /// `NSCache` stores objects, and ``Sampled`` is a value.
    private final class SampledBox {
        let sampled: Sampled
        init(_ sampled: Sampled) {
            self.sampled = sampled
        }
    }

    private let memoryCache = NSCache<NSURL, NSImage>()
    private let artworkCache = NSCache<NSURL, SampledBox>()
    private final class AssetBox {
        let asset: ArtworkAsset
        init(_ asset: ArtworkAsset) {
            self.asset = asset
        }
    }

    private let portableCache = NSCache<NSString, AssetBox>()
    private let diskCache: ArtworkDiskCache?
    private let artworkWriter: ArtworkWriteQueue?

    init(cacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Whisky/Artwork-v1", isDirectory: true)) {
        diskCache = cacheDirectory.map { ArtworkDiskCache(directory: $0) }
        artworkWriter = diskCache.map { ArtworkWriteQueue(cache: $0) }

        memoryCache.countLimit = 100
        memoryCache.totalCostLimit = 50 * 1_024 * 1_024 // 50MB limit
        // Keep enough cover images and palettes cached across scrolling and
        // view-mode switches so neither disk I/O nor colour sampling repeats.
        artworkCache.countLimit = 250
        artworkCache.totalCostLimit = 160 * 1_024 * 1_024
        portableCache.countLimit = 250
        portableCache.totalCostLimit = 32 * 1_024 * 1_024
    }

    /// Cross-toolkit clients receive a bounded PNG and a shared colour value.
    public func artwork(for request: ArtworkRequest) -> ArtworkAsset? {
        let url = request.source.url
        guard url.isFileURL, !Task.isCancelled else { return nil }
        let key = "\(request.source):\(versionedKey(for: url)):\(request.maxPixelSize)" as NSString
        if let cached = portableCache.object(forKey: key) {
            return cached.asset
        }
        let decoded: CGImage?
        switch request.source {
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            decoded = ArtworkDiskCache.thumbnailImage(source: source, maxPixelSize: request.maxPixelSize)
        case .executable:
            decoded = iconOrFallback(for: url).cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        guard let source = decoded else { return nil }
        let scale = min(1, Double(request.maxPixelSize) / Double(max(source.width, source.height)))
        let width = max(1, Int(Double(source.width) * scale))
        let height = max(1, Int(Double(source.height) * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage(), !Task.isCancelled else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, resized, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let asset = ArtworkAsset(data: data as Data, palette: IconPalette.palette(for: resized))
        portableCache.setObject(AssetBox(asset), forKey: key, cost: data.count)
        return asset
    }

    /// Reuses processed artwork from memory or the persistent derivative cache.
    public func cachedSampledArtwork(for url: URL) -> Sampled? {
        let key = versionedKey(for: url)
        if let cached = artworkCache.object(forKey: key as NSURL) {
            return cached.sampled
        }
        guard !Task.isCancelled, let cached = diskCache?.load(at: key) else { return nil }
        cacheArtwork(cached, key: key)
        return cached
    }

    /// Loads artwork from disk and samples its palette, caching both.
    ///
    /// Both halves are expensive and neither belongs on the main actor: the
    /// decode reads a JPEG off disk and the sampling rasterises into a bitmap
    /// context. A lazy grid re-runs a card's load task every time the card
    /// scrolls back into view, so without this the same banner is decoded over
    /// and over while somebody scrolls.
    ///
    /// - Parameter url: The image file to load.
    /// - Returns: The image and its palette, or `nil` if it could not be decoded.
    public func sampledArtwork(for url: URL) -> Sampled? {
        let key = versionedKey(for: url)
        if let cached = artworkCache.object(forKey: key as NSURL) {
            return cached.sampled
        }
        guard !Task.isCancelled, FileManager.default.fileExists(atPath: url.path) else { return nil }
        if let cached = diskCache?.load(at: key) {
            cacheArtwork(cached, key: key)
            return cached
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = ArtworkDiskCache.thumbnail(source: source)
        else { return nil }
        return sampleAndStore(image, key: key)
    }

    /// Decodes bounded thumbnails; derivative and palette survive application restarts.
    public func storeSampledArtwork(data: Data, for url: URL) -> Sampled? {
        let key = versionedKey(for: url)
        if let cached = artworkCache.object(forKey: key as NSURL) {
            return cached.sampled
        }
        guard !Task.isCancelled, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = ArtworkDiskCache.thumbnail(source: source)
        else { return nil }
        return sampleAndStore(image, key: key)
    }

    private func sampleAndStore(_ image: NSImage, key: URL) -> Sampled {
        let sampled = Sampled(
            image: image, ambient: IconPalette.blurredAmbient(for: image), palette: IconPalette.palette(for: image)
        )
        cacheArtwork(sampled, key: key)
        artworkWriter?.enqueue(sampled, at: key)
        return sampled
    }

    /// Waits for derivative persistence at explicit handoff and test boundaries.
    public func flushArtworkWrites() async {
        await artworkWriter?.flush()
    }

    private func cacheArtwork(_ sampled: Sampled, key: URL) {
        let cost = Int(sampled.image.size.width * sampled.image.size.height * 4)
            + Int(sampled.ambient.size.width * sampled.ambient.size.height * 4)
        artworkCache.setObject(SampledBox(sampled), forKey: key as NSURL, cost: cost)
    }

    /// The icon for a program plus the palette sampled from it.
    ///
    /// Sampling is the expensive half and is the reason this exists alongside
    /// ``iconOrFallback(for:peFile:)``: the icon itself is already cached, but
    /// its palette was being recomputed on every appearance.
    ///
    /// - Parameters:
    ///   - url: The URL of the PE executable file.
    ///   - peFile: An optional pre-parsed PE file.
    /// - Returns: The icon (or the system fallback) and its palette.
    public func sampledIcon(for url: URL, peFile: PEFile? = nil) -> Sampled {
        let key = versionedKey(for: url)
        if let cached = artworkCache.object(forKey: key as NSURL) {
            return cached.sampled
        }

        let image = iconOrFallback(for: url, peFile: peFile)
        let sampled = Sampled(image: image, palette: IconPalette.palette(for: image))
        artworkCache.setObject(SampledBox(sampled), forKey: key as NSURL)
        return sampled
    }

    /// Retrieves a cached icon or extracts and caches it.
    ///
    /// If the icon for the given URL is already cached, it is returned immediately.
    /// Otherwise, the PE file is parsed and the best icon is extracted and cached.
    ///
    /// - Parameters:
    ///   - url: The URL of the PE executable file.
    ///   - peFile: An optional pre-parsed PE file. If not provided, the file will be parsed.
    /// - Returns: The extracted icon, or `nil` if extraction fails.
    public func icon(for url: URL, peFile: PEFile? = nil) -> NSImage? {
        let key = versionedKey(for: url)
        if let cached = memoryCache.object(forKey: key as NSURL) {
            return cached
        }

        let pefile = peFile ?? (try? PEFile(url: url))
        // A nil result (no renderable icon, or a guarded/failed parse) is NOT
        // cached as a blank image: returning nil here lets `iconOrFallback`
        // reach the real system fallback icon on every call.
        guard let icon = pefile?.bestIcon() else { return nil }

        memoryCache.setObject(icon, forKey: key as NSURL)
        return icon
    }

    /// Asynchronously loads an icon, using cache when available.
    ///
    /// This is the preferred method for loading icons from SwiftUI views,
    /// as it can be called from a `Task` context.
    ///
    /// - Parameters:
    ///   - url: The URL of the PE executable file.
    ///   - peFile: An optional pre-parsed PE file. If not provided, the file will be parsed.
    /// - Returns: The extracted icon, or `nil` if extraction fails.
    public func iconAsync(for url: URL, peFile: PEFile? = nil) -> NSImage? {
        icon(for: url, peFile: peFile)
    }

    /// Returns the extracted icon, or a generic Windows-executable system icon
    /// if PE parsing fails. Use from views that should never render a blank tile.
    public func iconOrFallback(for url: URL, peFile: PEFile? = nil) -> NSImage {
        icon(for: url, peFile: peFile) ?? Self.fallbackIcon
    }

    private static let fallbackIcon: NSImage = NSWorkspace.shared.icon(for: .exe)

    private func versionedKey(for url: URL) -> URL {
        (diskCache ?? ArtworkDiskCache(directory: FileManager.default.temporaryDirectory)).location(for: url)
    }

    /// Removes a specific icon from the cache.
    ///
    /// Call this when a program is deleted or its executable is modified.
    ///
    /// - Parameter url: The URL of the PE file to remove from cache.
    public func invalidate(url: URL) {
        portableCache.removeAllObjects()
        let versioned = versionedKey(for: url)
        memoryCache.removeObject(forKey: versioned as NSURL)
        artworkCache.removeObject(forKey: versioned as NSURL)
        memoryCache.removeObject(forKey: url as NSURL)
        artworkCache.removeObject(forKey: url as NSURL)
        if let key = diskCache?.location(for: url) {
            artworkCache.removeObject(forKey: key as NSURL)
            artworkWriter?.remove(at: key)
        }
    }

    /// Clears all cached icons.
    ///
    /// This can be called in response to memory pressure or when bottles are deleted.
    public func clearCache() {
        portableCache.removeAllObjects()
        memoryCache.removeAllObjects()
        artworkCache.removeAllObjects()
    }
}
