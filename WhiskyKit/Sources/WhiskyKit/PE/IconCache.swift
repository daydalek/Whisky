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
import UniformTypeIdentifiers

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
public actor IconCache {
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

    private init() {
        memoryCache.countLimit = 100
        memoryCache.totalCostLimit = 50 * 1_024 * 1_024 // 50MB limit
        // Keep enough cover images and palettes cached across scrolling and
        // view-mode switches so neither disk I/O nor colour sampling repeats.
        artworkCache.countLimit = 250
        artworkCache.totalCostLimit = 160 * 1_024 * 1_024
    }

    /// Returns an already-cached sampled artwork entry without touching disk.
    public func cachedSampledArtwork(for url: URL) -> Sampled? {
        artworkCache.object(forKey: url as NSURL)?.sampled
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
        if let cached = artworkCache.object(forKey: url as NSURL) {
            return cached.sampled
        }

        guard let image = NSImage(contentsOf: url) else { return nil }
        let sampled = Sampled(
            image: image,
            ambient: IconPalette.blurredAmbient(for: image),
            palette: IconPalette.palette(for: image)
        )
        artworkCache.setObject(SampledBox(sampled), forKey: url as NSURL)
        return sampled
    }

    /// Decodes raw image data, samples its palette, and caches both under `url`.
    public func storeSampledArtwork(data: Data, for url: URL) -> Sampled? {
        if let cached = artworkCache.object(forKey: url as NSURL) {
            return cached.sampled
        }

        guard let image = NSImage(data: data) else { return nil }
        let sampled = Sampled(
            image: image,
            ambient: IconPalette.blurredAmbient(for: image),
            palette: IconPalette.palette(for: image)
        )
        artworkCache.setObject(SampledBox(sampled), forKey: url as NSURL)
        return sampled
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
        if let cached = artworkCache.object(forKey: url as NSURL) {
            return cached.sampled
        }

        let image = iconOrFallback(for: url, peFile: peFile)
        let sampled = Sampled(image: image, palette: IconPalette.palette(for: image))
        artworkCache.setObject(SampledBox(sampled), forKey: url as NSURL)
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
        if let cached = memoryCache.object(forKey: url as NSURL) {
            return cached
        }

        let pefile = peFile ?? (try? PEFile(url: url))
        // A nil result (no renderable icon, or a guarded/failed parse) is NOT
        // cached as a blank image: returning nil here lets `iconOrFallback`
        // reach the real system fallback icon on every call.
        guard let icon = pefile?.bestIcon() else { return nil }

        memoryCache.setObject(icon, forKey: url as NSURL)
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

    /// Removes a specific icon from the cache.
    ///
    /// Call this when a program is deleted or its executable is modified.
    ///
    /// - Parameter url: The URL of the PE file to remove from cache.
    public func invalidate(url: URL) {
        memoryCache.removeObject(forKey: url as NSURL)
        artworkCache.removeObject(forKey: url as NSURL)
    }

    /// Clears all cached icons.
    ///
    /// This can be called in response to memory pressure or when bottles are deleted.
    public func clearCache() {
        memoryCache.removeAllObjects()
        artworkCache.removeAllObjects()
    }
}
