//
//  ArtworkPortabilityTests.swift
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
import Testing
@testable import WhiskyCore

@Suite("Portable artwork")
struct ArtworkPortabilityTests {
    @Test func thumbnailRetainsOpaqueColourAndUsesAlphaWeightedAverages() throws {
        let opaque = [UInt8](repeating: 255, count: 4 * 8 * 4)
        let white = try #require(ArtworkPixels.thumbnail(rgba: opaque, width: 8, height: 4, maxPixelSize: 2))
        #expect(white.width == 2 && white.height == 1)
        #expect(white.bytes == [UInt8](repeating: 255, count: 8))
        let pixels: [UInt8] = [0, 255, 0, 255, 255, 0, 0, 0]
        let blended = try #require(ArtworkPixels.thumbnail(rgba: pixels, width: 2, height: 1, maxPixelSize: 1))
        #expect(blended.bytes == [0, 255, 0, 127])
        #expect(ArtworkPixels.thumbnail(rgba: pixels, width: Int.max, height: 1, maxPixelSize: 1) == nil)
    }

    @Test func paletteUsesColourAndPremultipliedAlpha() {
        #expect(IconPalette.sample(premultipliedRGBA: [0, 0, 0, 0]) == .neutral)
        #expect(IconPalette.sample(premultipliedRGBA: [1, 2, 3]) == .neutral)
        let pixels: [UInt8] = [255, 255, 255, 255, 26, 77, 13, 128, 0, 0, 0, 0]
        let palette = IconPalette.sample(premultipliedRGBA: pixels)
        #expect(abs(palette.green - 77.0 / 128) < 0.001)
        #expect(palette.green > palette.red)
        #expect(palette.deepened().prefersLightForeground)
        #expect(IconPalette.sample(premultipliedRGBA: [64, 64, 64, 255]).red == 64.0 / 255)
    }

    @Test func blurMatchesLegacyReferenceAcrossEdgesAndRadii() throws {
        for size in [1, 2, 5] {
            let pixels = (0 ..< size * size * 4).map { UInt8(($0 * 31) % 256) }
            for radius in [0, 1, 3] {
                let result = try #require(ArtworkPixels.blurredAmbient(
                    premultipliedRGBA: pixels,
                    size: size,
                    radius: radius
                ))
                #expect(result == reference(pixels, size: size, radius: radius))
            }
        }
        #expect(ArtworkPixels.blurredAmbient(premultipliedRGBA: [], size: Int.max) == nil)
        #expect(ArtworkPixels.blurredAmbient(premultipliedRGBA: [0, 0, 0, 0], size: 1, radius: -1) == nil)
    }

    private func reference(_ pixels: [UInt8], size: Int, radius: Int) -> [UInt8] {
        var result = pixels
        for _ in 0 ..< 3 {
            for horizontal in [true, false] {
                let source = result
                for row in 0 ..< size {
                    for column in 0 ..< size {
                        for channel in 0 ..< 3 {
                            let sum = (-radius ... radius).reduce(0) { value, offset in
                                let sourceColumn = horizontal ? min(max(column + offset, 0), size - 1) : column
                                let sourceRow = horizontal ? row : min(max(row + offset, 0), size - 1)
                                return value + Int(source[(sourceRow * size + sourceColumn) * 4 + channel])
                            }
                            result[(row * size + column) * 4 + channel] = UInt8(sum / (radius * 2 + 1))
                        }
                        result[(row * size + column) * 4 + 3] = 255
                    }
                }
            }
        }
        return result
    }

    @Test func imageHeadersBoundAllocationBeforeDecoding() {
        let png: [UInt8] = [
            137,
            80,
            78,
            71,
            13,
            10,
            26,
            10,
            0,
            0,
            0,
            13,
            73,
            72,
            68,
            82,
            0,
            0,
            0,
            32,
            0,
            0,
            0,
            16
        ]
        #expect(ArtworkHeader.dimensions(Data(png))?.width == 32)
        #expect(ArtworkHeader.dimensions(Data(png))?.height == 16)
        let jpeg: [UInt8] = [255, 216, 255, 224, 0, 2, 255, 194, 0, 8, 8, 0, 16, 0, 32, 1]
        #expect(ArtworkHeader.dimensions(Data(jpeg))?.width == 32)
        #expect(ArtworkHeader.dimensions(Data(jpeg))?.height == 16)
        var webp = Array("RIFF1234WEBPVP8X".utf8) + [UInt8](repeating: 0, count: 14)
        webp[24] = 31
        webp[27] = 15
        #expect(ArtworkHeader.dimensions(Data(webp))?.width == 32)
        #expect(ArtworkHeader.dimensions(Data(webp))?.height == 16)
        for prefix in 0 ..< png.count {
            #expect(ArtworkHeader.dimensions(Data(png.prefix(prefix))) == nil)
        }
        #expect(ArtworkHeader.dimensions(Data([255, 216, 255, 224, 0, 1])) == nil)
    }

    @Test func fileProviderHonoursSourceAndBudgets() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cover.png")
        let png: [UInt8] = [
            137,
            80,
            78,
            71,
            13,
            10,
            26,
            10,
            0,
            0,
            0,
            13,
            73,
            72,
            68,
            82,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            1
        ]
        try Data(png).write(to: file)
        let provider = FileArtworkProvider()
        #expect(await provider.artwork(for: ArtworkRequest(source: .image(file)))?.data == Data(png))
        #expect(await provider.artwork(for: ArtworkRequest(source: .executable(file))) == nil)
        #expect(await FileArtworkProvider(maximumBytes: 8).artwork(for: ArtworkRequest(source: .image(file))) == nil)
        var excessive = png
        excessive[16] = 127
        try Data(excessive).write(to: file)
        #expect(await provider.artwork(for: ArtworkRequest(source: .image(file))) == nil)
        #expect(ArtworkRequest(source: .image(file), maxPixelSize: Int.max).maxPixelSize == 1_024)
    }
}
