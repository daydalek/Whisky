//
//  IconCacheTests.swift
//  WhiskyKitTests
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
import Testing
@testable import WhiskyKit

@Suite("IconCache Tests")
struct IconCacheTests {
    @Test("Cache returns nil for non-existent file")
    func cacheReturnsNilForNonExistentFile() async {
        let cache = IconCache.shared
        let nonExistentURL = URL(fileURLWithPath: "/nonexistent/path/file.exe")

        let result = await cache.iconAsync(for: nonExistentURL)

        #expect(result == nil)
    }

    @Test("Cache returns nil for invalid PE file")
    func cacheReturnsNilForInvalidPEFile() async throws {
        let cache = IconCache.shared

        // Create a temporary file with invalid PE content
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("invalid_\(UUID().uuidString).exe")
        try "not a valid PE file".write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let result = await cache.iconAsync(for: tempFile)

        #expect(result == nil)
    }

    @Test("Clear cache removes all entries")
    func clearCacheRemovesAllEntries() async {
        let cache = IconCache.shared

        // Clear the cache
        await cache.clearCache()

        // Verify cache doesn't crash after clear (we can't directly inspect NSCache contents)
        let result = await cache.iconAsync(for: URL(fileURLWithPath: "/test/path.exe"))
        #expect(result == nil)
    }

    @Test("Invalidate removes specific entry")
    func invalidateRemovesSpecificEntry() async {
        let cache = IconCache.shared
        let testURL = URL(fileURLWithPath: "/test/specific/path.exe")

        // Invalidate the entry
        await cache.invalidate(url: testURL)

        // Verify cache doesn't crash after invalidate
        let result = await cache.iconAsync(for: testURL)
        #expect(result == nil)
    }

    @Test("Cache is shared singleton")
    func cacheIsSharedSingleton() {
        let cache1 = IconCache.shared
        let cache2 = IconCache.shared

        // Both should reference the same instance
        #expect(cache1 === cache2)
    }

    private func imageData(width: Int, height: Int, red: CGFloat) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: red, green: 0.2, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    @Test func artworkDerivativesSurviveNewCacheAndBoundDecodedSize() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("cover.png")
        try imageData(width: 2_048, height: 1_024, red: 0.8).write(to: original)
        let directory = root.appendingPathComponent("cache")
        let first = IconCache(cacheDirectory: directory)
        let sampled = try #require(await first.sampledArtwork(for: original))
        #expect(sampled.image.size == NSSize(width: 1_024, height: 512))
        let location = ArtworkDiskCache(directory: directory).location(for: original)
        await first.flushArtworkWrites()
        let saved = try Data(contentsOf: location)
        // A fresh instance exercises persistent lookup with no source decode or palette work.
        let second = IconCache(cacheDirectory: directory)
        let restored = try #require(await second.cachedSampledArtwork(for: original))
        #expect(restored.palette == sampled.palette)
        #expect(restored.image.size == sampled.image.size)
        #expect(try Data(contentsOf: location) == saved)
    }

    @Test func replacingArtworkInvalidatesMemoryAndDiskDerivatives() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("cover.png")
        let directory = root.appendingPathComponent("cache")
        try imageData(width: 100, height: 200, red: 0.9).write(to: original)
        let cache = IconCache(cacheDirectory: directory)
        let first = try #require(await cache.sampledArtwork(for: original))
        try imageData(width: 300, height: 100, red: 0.1).write(to: original)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: original.path
        )
        let changed = try #require(await cache.sampledArtwork(for: original))
        #expect(changed.image.size.width / changed.image.size.height == 3)
        #expect(changed.palette != first.palette)
        await cache.invalidate(url: original)
        #expect(await cache.cachedSampledArtwork(for: original) == nil)
    }

    @Test func corruptDerivativeFallsBackToOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("cover.png")
        try imageData(width: 100, height: 200, red: 0.5).write(to: original)
        let directory = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let location = ArtworkDiskCache(directory: directory).location(for: original)
        try Data("broken".utf8).write(to: location)
        let cache = IconCache(cacheDirectory: directory)
        #expect(await cache.sampledArtwork(for: original) != nil)
        await cache.flushArtworkWrites()
        #expect(ArtworkDiskCache(directory: directory).load(at: location) != nil)
    }

    @Test func derivativeCacheEvictsToItsByteBudget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try imageData(width: 100, height: 100, red: 0.8)
        let image = try #require(NSImage(data: data))
        var cache = ArtworkDiskCache(directory: directory, byteLimit: 1)
        let location = try cache.location(for: #require(URL(string: "https://example.invalid/cover.png")))
        cache.save(IconCache.Sampled(image: image, palette: .neutral), at: location)
        #expect(!FileManager.default.fileExists(atPath: location.path))
    }
}
