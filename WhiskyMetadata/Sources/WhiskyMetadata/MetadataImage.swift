//
//  MetadataImage.swift
//  WhiskyMetadata
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
#if os(macOS)
import ImageIO
#elseif os(Linux)
import CGdkPixbuf
#endif

public typealias MetadataNetworkAccess = @Sendable () async throws -> Void

enum MetadataImage {
    static func dimensions(_ data: Data, validatePixels: Bool = true) -> (width: Int, height: Int)? {
        #if os(macOS)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              !validatePixels || CGImageSourceCreateImageAtIndex(source, 0, nil) != nil,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5 ... 8).contains(orientation) ? (height, width) : (width, height)
        #elseif os(Linux)
        var width: Int32 = 0
        var height: Int32 = 0
        let valid = data.withUnsafeBytes { buffer in
            whisky_image_dimensions(buffer.bindMemory(to: UInt8.self).baseAddress, data.count, &width, &height)
        }
        return valid != 0 && width > 0 && height > 0 ? (Int(width), Int(height)) : nil
        #else
        return nil
        #endif
    }
}
