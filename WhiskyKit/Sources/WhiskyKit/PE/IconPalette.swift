//
//  IconPalette.swift
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
import WhiskyCore

public extension IconPalette {
    private static let sRGBSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Samples `image` and returns the colour it is built around.
    ///
    /// Grey and near-transparent pixels are dropped before anything is averaged.
    /// Windows icons are overwhelmingly a small mark on a transparent or white
    /// field, so averaging everything returns off-white for almost every program
    /// and every card comes out the same colour. What survives the filter is the
    /// mark itself, which is the part a person recognises.
    static func palette(for image: NSImage, sampleSize: Int = 24) -> IconPalette {
        guard let raw = rasterize(image, size: sampleSize) else { return .neutral }

        return sample(premultipliedRGBA: raw)
    }

    static func palette(for image: CGImage, sampleSize: Int = 24) -> IconPalette {
        guard let raw = rasterize(image, size: sampleSize) else { return .neutral }
        return sample(premultipliedRGBA: raw)
    }

    /// Pre-renders a compact, edge-clamped blurred bitmap (3-pass separable box blur,
    /// which converges to a Gaussian kernel) so views can display multi-hue cover
    /// ambiance with a plain texture draw instead of a live GPU `.blur(...)` pass.
    static func blurredAmbient(for image: NSImage, size: Int = 64, radius: Int = 6) -> NSImage? {
        guard let raw = rasterize(image, size: size),
              var pixels = ArtworkPixels.blurredAmbient(premultipliedRGBA: raw, size: size, radius: radius),
              let context = CGContext(
                  data: &pixels,
                  width: size,
                  height: size,
                  bitsPerComponent: 8,
                  bytesPerRow: size * 4,
                  space: sRGBSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let cgImage = context.makeImage()
        else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }

    private static func rasterize(_ image: NSImage, size: Int) -> [UInt8]? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return rasterize(cgImage, size: size)
    }

    private static func rasterize(_ cgImage: CGImage, size: Int) -> [UInt8]? {
        guard size > 0, size <= 2_048 else { return nil }

        var raw = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(
            data: &raw,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: sRGBSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        else { return nil }

        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        return raw
    }
}
