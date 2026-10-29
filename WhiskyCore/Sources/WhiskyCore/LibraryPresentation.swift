//
//  LibraryPresentation.swift
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

/// The existing on-disk layout is shared by both frontends and by portable hosts.
public enum LibraryStorageLayout {
    public static func metadata(for entry: LibraryEntry) -> URL {
        entry.metadataDirectory.appendingPathComponent(key(entry.metadataIdentity)).appendingPathExtension("json")
    }

    public static func activity(for entry: LibraryEntry) -> URL {
        entry.bottleURL.appendingPathComponent("Game Activity")
            .appendingPathComponent(key(entry.metadataIdentity)).appendingPathExtension("json")
    }

    public static func cachedCover(_ url: URL, directory: URL) -> URL {
        directory.appendingPathComponent("Covers").appendingPathComponent(key(url.absoluteString))
    }

    /// SHA-256, used exclusively for compatibility with existing storage filenames.
    public static func key(_ value: String) -> String {
        var bytes = Array(value.utf8)
        let bitCount = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 {
            bytes.append(0)
        }
        bytes += (0 ..< 8).reversed().map { UInt8(truncatingIfNeeded: bitCount >> ($0 * 8)) }
        var hash: [UInt32] = [
            0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A,
            0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19
        ]
        for start in stride(from: 0, to: bytes.count, by: 64) {
            compress(bytes, start: start, hash: &hash)
        }

        return hash.map { String(format: "%08x", $0) }.joined()
    }

    private static let constants: [UInt32] = [
        0x428A_2F98, 0x7137_4491, 0xB5C0_FBCF, 0xE9B5_DBA5, 0x3956_C25B, 0x59F1_11F1, 0x923F_82A4, 0xAB1C_5ED5,
        0xD807_AA98, 0x1283_5B01, 0x2431_85BE, 0x550C_7DC3, 0x72BE_5D74, 0x80DE_B1FE, 0x9BDC_06A7, 0xC19B_F174,
        0xE49B_69C1, 0xEFBE_4786, 0x0FC1_9DC6, 0x240C_A1CC, 0x2DE9_2C6F, 0x4A74_84AA, 0x5CB0_A9DC, 0x76F9_88DA,
        0x983E_5152, 0xA831_C66D, 0xB003_27C8, 0xBF59_7FC7, 0xC6E0_0BF3, 0xD5A7_9147, 0x06CA_6351, 0x1429_2967,
        0x27B7_0A85, 0x2E1B_2138, 0x4D2C_6DFC, 0x5338_0D13, 0x650A_7354, 0x766A_0ABB, 0x81C2_C92E, 0x9272_2C85,
        0xA2BF_E8A1, 0xA81A_664B, 0xC24B_8B70, 0xC76C_51A3, 0xD192_E819, 0xD699_0624, 0xF40E_3585, 0x106A_A070,
        0x19A4_C116, 0x1E37_6C08, 0x2748_774C, 0x34B0_BCB5, 0x391C_0CB3, 0x4ED8_AA4A, 0x5B9C_CA4F, 0x682E_6FF3,
        0x748F_82EE, 0x78A5_636F, 0x84C8_7814, 0x8CC7_0208, 0x90BE_FFFA, 0xA450_6CEB, 0xBEF9_A3F7, 0xC671_78F2
    ]

    private static func compress(_ bytes: [UInt8], start: Int, hash: inout [UInt32]) {
        var words = [UInt32](repeating: 0, count: 64)
        for index in 0 ..< 16 {
            let offset = start + index * 4
            words[index] = (0 ..< 4).reduce(UInt32(0)) { ($0 << 8) | UInt32(bytes[offset + $1]) }
        }
        for index in 16 ..< 64 {
            let word15 = words[index - 15], word2 = words[index - 2]
            let sigma0 = rotate(word15, 7) ^ rotate(word15, 18) ^ (word15 >> 3)
            let sigma1 = rotate(word2, 17) ^ rotate(word2, 19) ^ (word2 >> 10)
            words[index] = words[index - 16] &+ sigma0 &+ words[index - 7] &+ sigma1
        }
        var stateA = hash[0], stateB = hash[1], stateC = hash[2], stateD = hash[3]
        var stateE = hash[4], stateF = hash[5], stateG = hash[6], stateH = hash[7]
        for index in 0 ..< 64 {
            let sum1 = rotate(stateE, 6) ^ rotate(stateE, 11) ^ rotate(stateE, 25)
            let choice = (stateE & stateF) ^ (~stateE & stateG)
            let temp1 = stateH &+ sum1 &+ choice &+ constants[index] &+ words[index]
            let sum0 = rotate(stateA, 2) ^ rotate(stateA, 13) ^ rotate(stateA, 22)
            let majority = (stateA & stateB) ^ (stateA & stateC) ^ (stateB & stateC)
            stateH = stateG
            stateG = stateF
            stateF = stateE
            stateE = stateD &+ temp1
            stateD = stateC
            stateC = stateB
            stateB = stateA
            stateA = temp1 &+ sum0 &+ majority
        }
        for (index, value) in [stateA, stateB, stateC, stateD, stateE, stateF, stateG, stateH].enumerated() {
            hash[index] &+= value
        }
    }

    private static func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }
}

public struct LibraryPresentation: Sendable {
    public let metadata: GameMetadata?
    public let activity: GameActivity
    public let coverURL: URL?
    public let coverAspectRatio: Double?

    public init(
        metadata: GameMetadata? = nil,
        activity: GameActivity = GameActivity(),
        coverURL: URL? = nil,
        coverAspectRatio: Double? = nil
    ) {
        self.metadata = metadata
        self.activity = activity
        self.coverURL = coverURL
        self.coverAspectRatio = coverAspectRatio
    }

    /// Reads the same atomic JSON snapshots as the native app, without creating files.
    public static func load(for entry: LibraryEntry) throws -> LibraryPresentation {
        let metadataURL = LibraryStorageLayout.metadata(for: entry)
        let metadata: GameMetadata?
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            let size = try metadataURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 16 * 1_024 * 1_024 else { throw CocoaError(.fileReadTooLarge) }
            metadata = try GameMetadataRecord.decode(Data(contentsOf: metadataURL)).resolved().metadata
        } else {
            metadata = nil
        }
        let activity: GameActivity = try read(LibraryStorageLayout.activity(for: entry)) ?? GameActivity()
        let settings: CoverSelection? = try read(
            LibraryStorageLayout.metadata(for: entry).appendingPathExtension("cover-settings")
        )
        var cover: URL?
        if settings?.useCustomCover == true, let name = settings?.customFileName, UUID(uuidString: name) != nil {
            cover = entry.metadataDirectory.appendingPathComponent("Custom Covers").appendingPathComponent(name)
        }
        if cover == nil, let source = metadata?.coverURL {
            cover = source.isFileURL ? source : LibraryStorageLayout.cachedCover(
                source,
                directory: entry.metadataDirectory
            )
        }
        if let candidate = cover, !FileManager.default.fileExists(atPath: candidate.path) {
            cover = nil
        }
        let selected = cover ?? entry.artworkURL
        var aspect: Double?
        if let selected, let file = try? FileHandle(forReadingFrom: selected) {
            defer { try? file.close() }
            if let bytes = try file.read(upToCount: 256 * 1_024), let dimensions = ArtworkHeader.dimensions(bytes),
               dimensions.height > 0 {
                aspect = Double(dimensions.width) / Double(dimensions.height)
            }
        }
        return LibraryPresentation(metadata: metadata, activity: activity, coverURL: selected, coverAspectRatio: aspect)
    }

    private struct CoverSelection: Decodable {
        let useCustomCover: Bool
        let customFileName: String?
    }

    private static func read<T: Decodable>(_ url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 16 * 1_024 * 1_024 else { throw CocoaError(.fileReadTooLarge) }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
}
