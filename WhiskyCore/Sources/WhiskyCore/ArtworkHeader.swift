//
//  ArtworkHeader.swift
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

/// Header dimensions bound decoded allocation before a toolkit opens the image.
enum ArtworkHeader {
    static func dimensions(_ data: Data) -> (width: Int, height: Int)? {
        let bytes = Array(data)
        if bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]), bytes.count >= 24,
           bytes[12 ..< 16].elementsEqual([73, 72, 68, 82]) {
            return (bigEndian(bytes[16 ..< 20]), bigEndian(bytes[20 ..< 24]))
        }
        if bytes.starts(with: [255, 216]) {
            return jpegDimensions(bytes)
        }
        guard bytes.count >= 25, bytes[0 ..< 4].elementsEqual([82, 73, 70, 70]),
              bytes[8 ..< 12].elementsEqual([87, 69, 66, 80])
        else { return nil }
        return webpDimensions(bytes)
    }

    private static func bigEndian(_ bytes: ArraySlice<UInt8>) -> Int {
        bytes.reduce(0) { ($0 << 8) | Int($1) }
    }

    private static func littleEndian(_ bytes: ArraySlice<UInt8>) -> Int {
        bytes.reversed().reduce(0) { ($0 << 8) | Int($1) }
    }

    private static func jpegDimensions(_ bytes: [UInt8]) -> (width: Int, height: Int)? {
        let frames: Set<UInt8> = [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF]
        var offset = 2
        while offset < bytes.count {
            guard bytes[offset] == 255 else { return nil }
            while offset < bytes.count, bytes[offset] == 255 {
                offset += 1
            }
            guard offset < bytes.count else { return nil }
            let marker = bytes[offset]
            offset += 1
            if marker == 0xD9 || marker == 0xDA {
                return nil
            }
            if marker == 1 || (0xD0 ... 0xD8).contains(marker) {
                continue
            }
            guard offset + 2 <= bytes.count else { return nil }
            let length = bigEndian(bytes[offset ..< offset + 2])
            guard length >= 2, length <= bytes.count - offset else { return nil }
            if frames.contains(marker) {
                guard length >= 8 else { return nil }
                return (bigEndian(bytes[offset + 5 ..< offset + 7]), bigEndian(bytes[offset + 3 ..< offset + 5]))
            }
            offset += length
        }
        return nil
    }

    /// PNG IHDR: w3.org/TR/png/ ; WebP headers: rfc-editor.org/rfc/rfc9649.html
    private static func webpDimensions(_ bytes: [UInt8]) -> (width: Int, height: Int)? {
        let chunk = String(bytes: bytes[12 ..< 16], encoding: .ascii)
        switch chunk {
        case "VP8X" where bytes.count >= 30:
            return (littleEndian(bytes[24 ..< 27]) + 1, littleEndian(bytes[27 ..< 30]) + 1)
        case "VP8L" where bytes[20] == 0x2F:
            let bits = littleEndian(bytes[21 ..< 25])
            return ((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1)
        case "VP8 " where bytes.count >= 30 && bytes[23 ..< 26].elementsEqual([0x9D, 1, 0x2A]):
            return (littleEndian(bytes[26 ..< 28]) & 0x3FFF, littleEndian(bytes[28 ..< 30]) & 0x3FFF)
        default: return nil
        }
    }
}
