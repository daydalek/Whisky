//
//  ArtworkDiskCache.swift
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
import CryptoKit
import ImageIO
import WhiskyCore

/// Disposable, versioned derivatives. Source identity includes file size and modification time.
/// Used only from IconCache's actor, keeping decoding and bounded cache maintenance off the UI thread.
struct ArtworkDiskCache {
    let directory: URL
    private var estimatedBytes: Int?
    private let byteLimit: Int

    init(directory: URL, byteLimit: Int = 256 * 1_024 * 1_024) {
        self.directory = directory
        self.byteLimit = byteLimit
    }

    private struct CachedFile {
        let url: URL
        let size: Int
        let date: Date
    }

    private struct Record: Codable {
        let image: Data
        let ambient: Data
        let red: Double
        let green: Double
        let blue: Double
    }

    func location(for url: URL) -> URL {
        // URL.resourceValues may reuse an earlier stat across an in-place cover replacement.
        let attributes = url.isFileURL ? try? FileManager.default.attributesOfItem(atPath: url.path) : nil
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let stamp = url.isFileURL
            ? "\(attributes?[.size] ?? 0):\(modified):\(attributes?[.systemFileNumber] ?? 0)"
            : "remote"
        let key = "v1:\(url.absoluteString):\(stamp)"
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".plist")
    }

    func load(at location: URL) -> IconCache.Sampled? {
        guard let data = try? Data(contentsOf: location, options: .mappedIfSafe),
              let record = try? PropertyListDecoder().decode(Record.self, from: data),
              let image = Self.decode(record.image), let ambient = Self.decode(record.ambient)
        else { return nil }
        return IconCache.Sampled(
            image: image, ambient: ambient,
            palette: IconPalette(red: record.red, green: record.green, blue: record.blue)
        )
    }

    mutating func save(_ sampled: IconCache.Sampled, at location: URL) {
        guard let image = Self.png(sampled.image), let ambient = Self.png(sampled.ambient) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let record = Record(
                image: image, ambient: ambient,
                red: sampled.palette.red, green: sampled.palette.green, blue: sampled.palette.blue
            )
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(record)
            try data.write(to: location, options: .atomic)
            if let estimatedBytes {
                self.estimatedBytes = estimatedBytes + data.count
            }
            // Scan once per cache lifetime, then only when the byte budget is reached.
            if estimatedBytes == nil || (estimatedBytes ?? 0) > byteLimit {
                trim()
            }
        } catch {
            // Cache failures leave the source artwork available.
        }
    }

    private mutating func trim() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles
        )
        else { return }
        let files = urls.compactMap { url -> CachedFile? in
            guard url.pathExtension == "plist", let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return CachedFile(
                url: url,
                size: values.fileSize ?? 0,
                date: values.contentModificationDate ?? .distantPast
            )
        }.sorted { $0.date < $1.date }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files where total > byteLimit {
            if (try? FileManager.default.removeItem(at: file.url)) != nil {
                total -= file.size
            }
        }
        estimatedBytes = total
    }

    static func thumbnail(source: CGImageSource) -> NSImage? {
        guard let image = thumbnailImage(source: source) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    static func thumbnailImage(source: CGImageSource, maxPixelSize: Int = 1_024) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func decode(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(
                  source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              )
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private static func png(_ image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}
