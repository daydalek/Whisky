//
//  ArtworkPixels.swift
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

public struct ArtworkPixelBuffer: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let bytes: [UInt8]
}

public enum ArtworkPixels {
    private struct Channels {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8
    }

    /// Box downsampling averages alpha-weighted colour and retains exact opaque endpoints.
    public static func thumbnail(
        rgba: [UInt8], width: Int, height: Int, maxPixelSize: Int
    ) -> ArtworkPixelBuffer? {
        guard width > 0, height > 0, width <= 8_192, height <= 8_192,
              width * height <= 4 * 1_024 * 1_024, rgba.count == width * height * 4
        else { return nil }
        let limit = min(max(maxPixelSize, 1), 1_024)
        let scale = min(1, Double(limit) / Double(max(width, height)))
        let targetWidth = max(1, Int(Double(width) * scale))
        let targetHeight = max(1, Int(Double(height) * scale))
        if targetWidth == width, targetHeight == height {
            return ArtworkPixelBuffer(width: width, height: height, bytes: rgba)
        }
        var result = [UInt8](repeating: 0, count: targetWidth * targetHeight * 4)
        for row in 0 ..< targetHeight {
            for column in 0 ..< targetWidth {
                let rows = row * height / targetHeight ..< (row + 1) * height / targetHeight
                let columns = column * width / targetWidth ..< (column + 1) * width / targetWidth
                let pixel = average(rgba, width: width, rows: rows, columns: columns)
                let output = (row * targetWidth + column) * 4
                result[output] = pixel.red
                result[output + 1] = pixel.green
                result[output + 2] = pixel.blue
                result[output + 3] = pixel.alpha
            }
        }
        return ArtworkPixelBuffer(width: targetWidth, height: targetHeight, bytes: result)
    }

    private static func average(
        _ bytes: [UInt8], width: Int, rows: Range<Int>, columns: Range<Int>
    ) -> Channels {
        var red: UInt64 = 0, green: UInt64 = 0, blue: UInt64 = 0, alpha: UInt64 = 0
        for row in rows {
            for column in columns {
                let index = (row * width + column) * 4
                let value = UInt64(bytes[index + 3])
                alpha += value
                red += UInt64(bytes[index]) * value
                green += UInt64(bytes[index + 1]) * value
                blue += UInt64(bytes[index + 2]) * value
            }
        }
        let count = UInt64(rows.count * columns.count)
        guard alpha > 0 else { return Channels(red: 0, green: 0, blue: 0, alpha: 0) }
        return Channels(
            red: UInt8(red / alpha),
            green: UInt8(green / alpha),
            blue: UInt8(blue / alpha),
            alpha: UInt8(alpha / count)
        )
    }

    /// Three edge-clamped box-blur passes preserve the existing opaque ambient texture.
    public static func blurredAmbient(premultipliedRGBA: [UInt8], size: Int, radius: Int = 6) -> [UInt8]? {
        guard size > 0, size <= 2_048, radius >= 0, radius <= 2_048,
              premultipliedRGBA.count == size * size * 4
        else { return nil }
        var pixels = premultipliedRGBA
        var scratch = pixels
        for _ in 0 ..< 3 {
            blur(src: pixels, dst: &scratch, size: size, radius: radius, horizontal: true)
            blur(src: scratch, dst: &pixels, size: size, radius: radius, horizontal: false)
        }
        return pixels
    }

    private static func blur(src: [UInt8], dst: inout [UInt8], size: Int, radius: Int, horizontal: Bool) {
        let span = radius * 2 + 1
        for line in 0 ..< size {
            func index(_ position: Int) -> Int {
                let clamped = min(max(position, 0), size - 1)
                return (horizontal ? line * size + clamped : clamped * size + line) * 4
            }
            var sums = (red: 0, green: 0, blue: 0)
            for position in -radius ... radius {
                let source = index(position)
                sums.red += Int(src[source])
                sums.green += Int(src[source + 1])
                sums.blue += Int(src[source + 2])
            }
            for position in 0 ..< size {
                let output = index(position)
                dst[output] = UInt8(sums.red / span)
                dst[output + 1] = UInt8(sums.green / span)
                dst[output + 2] = UInt8(sums.blue / span)
                dst[output + 3] = 255
                let leaving = index(position - radius)
                let entering = index(position + radius + 1)
                sums.red += Int(src[entering]) - Int(src[leaving])
                sums.green += Int(src[entering + 1]) - Int(src[leaving + 1])
                sums.blue += Int(src[entering + 2]) - Int(src[leaving + 2])
            }
        }
    }
}
