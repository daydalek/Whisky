//
//  main.swift
//  realcugan-helper
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

// Coverage upscaler: Real-CUGAN models-se 2x for library covers.
//
// The Core ML package is a fixed-size program (see the Wine repository's
// convert-realcugan-coreml.py), so this tool feeds it 384x384 windows of the
// cover with an 18-pixel reflected halo and blends the overlapping results back
// together. That is what makes an arbitrary cover size possible with a single
// model.
//
// Input and output are PNG/JPEG files; the model directory is the compiled
// .mlmodelc. Everything is planar RGB float32, matching the graph.

import CoreGraphics
import CoreML
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Content window the model was generated for, in pixels.
let tile = 384
/// Reflected context the network expects on every side.
let halo = 18
/// Neighbouring windows share this many pixels so the seam can be blended.
let overlap = 32
let step = tile - overlap

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Covers are tagged sRGB in practice, and a device colour space would convert
/// them to the display profile and back — which reads as a saturation shift.
let sRGB: CGColorSpace = {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
        fatalError("sRGB color space is unavailable")
    }
    return colorSpace
}()

/// BGRA in memory, which is what every byte offset below assumes.
let bitmapLayout =
    CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

/// Reflect-101, the padding the ncnn graph was trained with.
func reflected(_ coordinate: Int, _ length: Int) -> Int {
    guard length > 1 else { return 0 }
    let period = 2 * length - 2
    var value = coordinate % period
    if value < 0 { value += period }
    return value < length ? value : period - value
}

/// Window origins that cover `length` with the last one flush to the edge.
func origins(_ length: Int) -> [Int] {
    if length <= tile { return [0] }
    var result: [Int] = []
    var origin = 0
    while origin + tile < length {
        result.append(origin)
        origin += step
    }
    result.append(length - tile)
    return result
}

/// Linear ramp across the shared band, so two neighbours sum to something
/// stable instead of one hard edge winning.
func ramp(_ distance: Int) -> Float {
    if distance >= overlap { return 1 }
    if distance < 0 { return 0 }
    return (Float(distance) + 0.5) / Float(overlap)
}

struct Cover {
    let width: Int
    let height: Int
    /// BGRA, the layout CoreGraphics writes for 32-bit little-endian order with
    /// alpha first — the same buffer the Wine side feeds the model.
    var pixels: [UInt8]
}

func load(_ url: URL) throws -> Cover {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        throw Failure("cannot read \(url.path)")
    }
    let width = image.width, height = image.height
    guard width > 0, height > 0 else { throw Failure("empty image") }
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: sRGB, bitmapInfo: bitmapLayout
    )
    else {
        throw Failure("cannot create bitmap context")
    }
    // Copy, not blend: the destination starts as uninitialised memory.
    context.setBlendMode(.copy)
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return Cover(width: width, height: height, pixels: pixels)
}

func save(_ cover: Cover, to url: URL) throws {
    guard let context = CGContext(
        data: nil, width: cover.width, height: cover.height, bitsPerComponent: 8,
        bytesPerRow: cover.width * 4, space: sRGB, bitmapInfo: bitmapLayout
    ), let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    )
    else {
        throw Failure("cannot write \(url.path)")
    }
    try cover.pixels.withUnsafeBytes { rawBuffer in
        guard let sourceAddress = rawBuffer.baseAddress, let destinationAddress = context.data else {
            throw Failure("cannot access image buffers")
        }
        destinationAddress.copyMemory(from: sourceAddress, byteCount: rawBuffer.count)
    }
    guard let image = context.makeImage() else { throw Failure("cannot encode image") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw Failure("cannot finalize PNG") }
}

func inputTensor(for cover: Cover, originX: Int, originY: Int) throws -> MLMultiArray {
    let side = tile + halo * 2
    let tensor = try MLMultiArray(
        shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float32
    )
    let planes = tensor.dataPointer.bindMemory(to: Float.self, capacity: 3 * side * side)
    let scale = 1.0 / 255.0

    for channelIndex in 0 ..< 3 {
        let channelPlane = planes + channelIndex * side * side
        for tileY in 0 ..< side {
            let imageY = reflected(originY + tileY - halo, cover.height)
            let sourceRowOffset = (imageY * cover.width) * 4
            let tensorRow = channelPlane + tileY * side
            for tileX in 0 ..< side {
                let imageX = reflected(originX + tileX - halo, cover.width)
                tensorRow[tileX] =
                    Float(cover.pixels[sourceRowOffset + imageX * 4 + 2 - channelIndex]) * Float(scale)
            }
        }
    }
    return tensor
}

func predictionOutput(for tensor: MLMultiArray, model: MLModel) throws -> MLMultiArray {
    let input = try MLDictionaryFeatureProvider(dictionary: ["input_rgb": tensor])
    let prediction = try model.prediction(from: input)
    guard let output = prediction.featureValue(for: "output_rgb")?.multiArrayValue,
          output.dataType == .float32, output.shape.count == 4
    else {
        throw Failure("unexpected model output")
    }
    return output
}

struct BlendAccumulator {
    let outputWidth: Int
    var sums: [Float]
    var weights: [Float]
}

func blendTile(
    _ output: MLMultiArray,
    cover: Cover,
    originX: Int,
    originY: Int,
    into accumulator: inout BlendAccumulator
) {
    let outputWidthFromModel = output.shape[3].intValue
    let outputPlanes = output.dataPointer.bindMemory(
        to: Float.self, capacity: 3 * outputWidthFromModel * outputWidthFromModel
    )
    let visibleWidth = min(tile, cover.width - originX)
    let visibleHeight = min(tile, cover.height - originY)

    for tileY in 0 ..< visibleHeight {
        let outputY = (originY + tileY) * 2
        var verticalWeight: Float = 1
        if originY > 0 { verticalWeight = min(verticalWeight, ramp(tileY)) }
        if originY + tile < cover.height {
            verticalWeight = min(verticalWeight, ramp(tile - 1 - tileY))
        }
        for tileX in 0 ..< visibleWidth {
            let outputX = (originX + tileX) * 2
            var horizontalWeight: Float = 1
            if originX > 0 { horizontalWeight = min(horizontalWeight, ramp(tileX)) }
            if originX + tile < cover.width {
                horizontalWeight = min(horizontalWeight, ramp(tile - 1 - tileX))
            }
            let weight = horizontalWeight * verticalWeight
            guard weight > 0 else { continue }
            for outputOffsetY in 0 ..< 2 {
                for outputOffsetX in 0 ..< 2 {
                    let pixelX = outputX + outputOffsetX
                    let pixelY = outputY + outputOffsetY
                    let outputIndex = pixelY * accumulator.outputWidth + pixelX
                    let sourceX = tileX * 2 + outputOffsetX
                    let sourceY = tileY * 2 + outputOffsetY
                    for channelIndex in 0 ..< 3 {
                        let sampleIndex =
                            channelIndex * outputWidthFromModel * outputWidthFromModel
                                + sourceY * outputWidthFromModel + sourceX
                        accumulator.sums[outputIndex * 3 + channelIndex] +=
                            outputPlanes[sampleIndex] * weight
                    }
                    accumulator.weights[outputIndex] += weight
                }
            }
        }
    }
}

func renderedPixels(_ accumulator: BlendAccumulator, height: Int) -> [UInt8] {
    var pixels = [UInt8](repeating: 255, count: accumulator.outputWidth * height * 4)
    for pixelY in 0 ..< height {
        for pixelX in 0 ..< accumulator.outputWidth {
            let outputIndex = pixelY * accumulator.outputWidth + pixelX
            let weight = max(accumulator.weights[outputIndex], 0.0001)
            for channelIndex in 0 ..< 3 {
                let value =
                    (accumulator.sums[outputIndex * 3 + channelIndex] / weight)
                        .clamped(to: 0 ... 1) * 255
                pixels[outputIndex * 4 + 2 - channelIndex] = UInt8(value.rounded())
            }
        }
    }
    return pixels
}

/// One 2x pass over the whole cover.
func upscale(_ cover: Cover, with model: MLModel) throws -> Cover {
    let outputWidth = cover.width * 2
    let outputHeight = cover.height * 2
    var accumulator = BlendAccumulator(
        outputWidth: outputWidth,
        sums: [Float](repeating: 0, count: outputWidth * outputHeight * 3),
        weights: [Float](repeating: 0, count: outputWidth * outputHeight)
    )

    for originY in origins(cover.height) {
        for originX in origins(cover.width) {
            let tensor = try inputTensor(for: cover, originX: originX, originY: originY)
            let output = try predictionOutput(for: tensor, model: model)
            blendTile(
                output,
                cover: cover,
                originX: originX,
                originY: originY,
                into: &accumulator
            )
        }
    }
    return Cover(
        width: outputWidth,
        height: outputHeight,
        pixels: renderedPixels(accumulator, height: outputHeight)
    )
}

extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

func argument(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let modelPath = argument("--model", in: arguments),
      let inputPath = argument("--in", in: arguments),
      let outputPath = argument("--out", in: arguments)
else {
    FileHandle.standardError
        .write(Data("usage: realcugan-helper --model <dir> --in <image> --out <png> [--passes N]\n".utf8))
    exit(2)
}

let passes = max(1, Int(argument("--passes", in: arguments) ?? "1") ?? 1)

do {
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuAndNeuralEngine
    let model = try MLModel(contentsOf: URL(fileURLWithPath: modelPath), configuration: configuration)
    var cover = try load(URL(fileURLWithPath: inputPath))
    for _ in 0 ..< passes {
        cover = try upscale(cover, with: model)
    }
    try save(cover, to: URL(fileURLWithPath: outputPath))
} catch {
    FileHandle.standardError.write(Data("realcugan-helper: \(error)\n".utf8))
    exit(1)
}
