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
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
/// BGRA in memory, which is what every byte offset below assumes.
let bitmapLayout = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

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
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw Failure("cannot read \(url.path)")
    }
    let width = image.width, height = image.height
    guard width > 0, height > 0 else { throw Failure("empty image") }
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: sRGB, bitmapInfo: bitmapLayout
    ) else {
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
    ) else {
        throw Failure("cannot write \(url.path)")
    }
    cover.pixels.withUnsafeBytes { raw in
        context.data?.copyMemory(from: raw.baseAddress!, byteCount: raw.count)
    }
    guard let image = context.makeImage() else { throw Failure("cannot encode image") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw Failure("cannot finalize PNG") }
}

/// One 2x pass over the whole cover.
func upscale(_ cover: Cover, with model: MLModel) throws -> Cover {
    let outputWidth = cover.width * 2, outputHeight = cover.height * 2
    var sums = [Float](repeating: 0, count: outputWidth * outputHeight * 3)
    var weights = [Float](repeating: 0, count: outputWidth * outputHeight)

    let columns = origins(cover.width), rows = origins(cover.height)
    let side = tile + halo * 2
    let tensor = try MLMultiArray(
        shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float32
    )
    let planes = tensor.dataPointer.bindMemory(to: Float.self, capacity: 3 * side * side)
    let scale = 1.0 / 255.0

    for originY in rows {
        for originX in columns {
            // Fill the window: the centre is the tile, the ring is reflected
            // context (or the neighbouring cover content when there is some).
            for channel in 0 ..< 3 {
                let plane = planes + channel * side * side
                for y in 0 ..< side {
                    let imageY = reflected(originY + y - halo, cover.height)
                    let base = (imageY * cover.width) * 4
                    let row = plane + y * side
                    for x in 0 ..< side {
                        let imageX = reflected(originX + x - halo, cover.width)
                        row[x] = Float(cover.pixels[base + imageX * 4 + 2 - channel]) * Float(scale)
                    }
                }
            }
            let input = try MLDictionaryFeatureProvider(dictionary: ["input_rgb": tensor])
            let prediction = try model.prediction(from: input)
            guard let result = prediction.featureValue(for: "output_rgb")?.multiArrayValue,
                  result.dataType == .float32, result.shape.count == 4 else {
                throw Failure("unexpected model output")
            }
            let outWidth = result.shape[3].intValue
            let outPlanes = result.dataPointer.bindMemory(
                to: Float.self, capacity: 3 * outWidth * outWidth
            )
            // Blend the part of this window that lies inside the cover.
            let visibleX = min(tile, cover.width - originX)
            let visibleY = min(tile, cover.height - originY)
            for y in 0 ..< visibleY {
                let outputY = (originY + y) * 2
                var wy: Float = 1
                if originY > 0 { wy = min(wy, ramp(y)) }
                if originY + tile < cover.height { wy = min(wy, ramp(tile - 1 - y)) }
                for x in 0 ..< visibleX {
                    let outputX = (originX + x) * 2
                    var wx: Float = 1
                    if originX > 0 { wx = min(wx, ramp(x)) }
                    if originX + tile < cover.width { wx = min(wx, ramp(tile - 1 - x)) }
                    let weight = wx * wy
                    guard weight > 0 else { continue }
                    for dy in 0 ..< 2 {
                        for dx in 0 ..< 2 {
                            let px = outputX + dx, py = outputY + dy
                            let index = py * outputWidth + px
                            let sourceX = x * 2 + dx, sourceY = y * 2 + dy
                            for channel in 0 ..< 3 {
                                let sample = outPlanes[channel * outWidth * outWidth + sourceY * outWidth + sourceX]
                                sums[index * 3 + channel] += sample * weight
                            }
                            weights[index] += weight
                        }
                    }
                }
            }
        }
    }

    var pixels = [UInt8](repeating: 255, count: outputWidth * outputHeight * 4)
    for y in 0 ..< outputHeight {
        for x in 0 ..< outputWidth {
            let index = y * outputWidth + x
            let weight = max(weights[index], 0.0001)
            for channel in 0 ..< 3 {
                let value = (sums[index * 3 + channel] / weight).clamped(to: 0 ... 1) * 255
                pixels[index * 4 + 2 - channel] = UInt8(value.rounded())
            }
        }
    }
    return Cover(width: outputWidth, height: outputHeight, pixels: pixels)
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
      let outputPath = argument("--out", in: arguments) else {
    FileHandle.standardError.write(Data("usage: realcugan-helper --model <dir> --in <image> --out <png> [--passes N]\n".utf8))
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
