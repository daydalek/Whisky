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

/// The colour a program's own icon is built around.
///
/// Whisky reads icons out of the executable's PE resources, so it can colour a
/// program's card from the program itself rather than from artwork someone had
/// to publish. A launcher that fetches store art has no equivalent: this works
/// for a game nobody has ever written a store page for.
public struct IconPalette: Equatable, Sendable {
    /// The colour the icon is built around, as sRGB in 0...1.
    public let red: Double
    public let green: Double
    public let blue: Double

    /// Whether that colour is dark enough that white text sits comfortably on it.
    public var prefersLightForeground: Bool {
        luminance < 0.55
    }

    /// Rec. 709 relative luminance, which is what decides foreground contrast.
    public var luminance: Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    public init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    /// The neutral used for icons with no colour of their own, and for anything
    /// that fails to decode. Deliberately not black: a card that falls back
    /// should still look like a card.
    public static let neutral = IconPalette(red: 0.42, green: 0.44, blue: 0.5)

    /// The same hue taken to a fixed luminance.
    ///
    /// A card has to be readable whatever the icon is, and icons range from
    /// near-black to fluorescent yellow. Scaling to a target luminance keeps
    /// each program's own colour while guaranteeing the contrast underneath the
    /// label, which picking a tint by eye per program cannot do.
    public func deepened(toLuminance target: Double = 0.14) -> IconPalette {
        let current = luminance
        guard current > 0.001 else {
            return IconPalette(red: target, green: target, blue: target)
        }
        let scale = target / current
        // Above 1 the scale would blow out a dark icon into a wash; a dark icon
        // is allowed to stay dark, it just cannot go darker than the target.
        return IconPalette(
            red: red * min(scale, 1.6),
            green: green * min(scale, 1.6),
            blue: blue * min(scale, 1.6)
        )
    }
}

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

        var coloured = (red: 0.0, green: 0.0, blue: 0.0, weight: 0.0)
        var greyTotal = (red: 0.0, green: 0.0, blue: 0.0, weight: 0.0)

        for index in stride(from: 0, to: raw.count, by: 4) {
            let alphaByte = raw[index + 3]
            // alpha > 0.4 corresponds to alphaByte > 102 (102 / 255 == 0.4)
            guard alphaByte > 102 else { continue }
            let invAlpha = 1.0 / Double(alphaByte)
            let red = Double(raw[index]) * invAlpha
            let green = Double(raw[index + 1]) * invAlpha
            let blue = Double(raw[index + 2]) * invAlpha

            let highest = max(red, green, blue)
            let lowest = min(red, green, blue)
            let saturation = highest > 0 ? (highest - lowest) / highest : 0

            // Weighted towards saturated mid-tones: a colour that is nearly
            // black or nearly white carries no identity even when it is the
            // most common pixel in the icon.
            if saturation > 0.25, highest > 0.15 {
                let weight = max(saturation * (1 - abs(highest - 0.6)), 0.05)
                coloured.red += red * weight
                coloured.green += green * weight
                coloured.blue += blue * weight
                coloured.weight += weight
            } else {
                greyTotal.red += red
                greyTotal.green += green
                greyTotal.blue += blue
                greyTotal.weight += 1
            }
        }

        if coloured.weight > 0 {
            return IconPalette(
                red: coloured.red / coloured.weight,
                green: coloured.green / coloured.weight,
                blue: coloured.blue / coloured.weight
            )
        }

        // A genuinely greyscale icon still gets its own shade rather than the
        // shared fallback, so two grey icons do not look like the same program.
        guard greyTotal.weight > 0 else { return .neutral }
        return IconPalette(
            red: greyTotal.red / greyTotal.weight,
            green: greyTotal.green / greyTotal.weight,
            blue: greyTotal.blue / greyTotal.weight
        )
    }

    /// Pre-renders a compact, edge-clamped blurred bitmap (3-pass separable box blur,
    /// which converges to a Gaussian kernel) so views can display multi-hue cover
    /// ambiance with a plain texture draw instead of a live GPU `.blur(...)` pass.
    static func blurredAmbient(for image: NSImage, size: Int = 64, radius: Int = 6) -> NSImage? {
        guard var pixels = rasterize(image, size: size) else { return nil }
        var scratch = pixels
        for _ in 0 ..< 3 {
            boxBlurHorizontal(src: pixels, dst: &scratch, size: size, radius: radius)
            boxBlurVertical(src: scratch, dst: &pixels, size: size, radius: radius)
        }
        guard let context = CGContext(
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

    private static func boxBlurHorizontal(src: [UInt8], dst: inout [UInt8], size: Int, radius: Int) {
        let span = radius * 2 + 1
        for row in 0 ..< size {
            let rowOffset = row * size * 4
            for col in 0 ..< size {
                var rSum = 0, gSum = 0, bSum = 0
                for delta in -radius ... radius {
                    let clampedX = min(max(col + delta, 0), size - 1)
                    let idx = rowOffset + clampedX * 4
                    rSum += Int(src[idx])
                    gSum += Int(src[idx + 1])
                    bSum += Int(src[idx + 2])
                }
                let outIdx = rowOffset + col * 4
                dst[outIdx] = UInt8(rSum / span)
                dst[outIdx + 1] = UInt8(gSum / span)
                dst[outIdx + 2] = UInt8(bSum / span)
                dst[outIdx + 3] = 255
            }
        }
    }

    private static func boxBlurVertical(src: [UInt8], dst: inout [UInt8], size: Int, radius: Int) {
        let span = radius * 2 + 1
        for row in 0 ..< size {
            for col in 0 ..< size {
                var rSum = 0, gSum = 0, bSum = 0
                for delta in -radius ... radius {
                    let clampedY = min(max(row + delta, 0), size - 1)
                    let idx = (clampedY * size + col) * 4
                    rSum += Int(src[idx])
                    gSum += Int(src[idx + 1])
                    bSum += Int(src[idx + 2])
                }
                let outIdx = (row * size + col) * 4
                dst[outIdx] = UInt8(rSum / span)
                dst[outIdx + 1] = UInt8(gSum / span)
                dst[outIdx + 2] = UInt8(bSum / span)
                dst[outIdx + 3] = 255
            }
        }
    }

    private static func rasterize(_ image: NSImage, size: Int) -> [UInt8]? {
        guard size > 0,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

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
