//
//  SteamLaunchReceipt.swift
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

import Darwin
import Foundation

/// A bounded, handle-verified cursor over the request log. Lost continuity disables retries.
public struct SteamLaunchReceipt: Sendable {
    public enum Status: String, Codable, Sendable, Equatable { case waiting, accepted, unavailable }
    public let url: URL
    private let offset: UInt64
    private let device: Int32?
    private let inode: UInt64?
    private let anchor: Data
    private static let maximumRead: UInt64 = 524_288

    public init(steamRoot: URL) {
        url = steamRoot.appendingPathComponent("logs/console_log.txt")
        var info = stat()
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if fstat(handle.fileDescriptor, &info) == 0, info.st_size >= 0 {
                offset = UInt64(info.st_size)
                device = info.st_dev
                inode = info.st_ino
                try? handle.seek(toOffset: offset > 256 ? offset - 256 : 0)
                anchor = (try? handle.read(upToCount: 256)) ?? Data()
                return
            }
        }
        offset = 0
        device = nil
        inode = nil
        anchor = Data()
    }

    public func wasAccepted(appID: Int) -> Bool {
        status(appID: appID) == .accepted
    }

    public func status(appID: Int) -> Status {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unavailable }
        defer { try? handle.close() }
        do {
            var info = stat()
            guard fstat(handle.fileDescriptor, &info) == 0,
                  device == info.st_dev, inode == info.st_ino, inode != nil, info.st_size >= 0
            else { return .unavailable }
            let end = UInt64(info.st_size)
            guard end >= offset, end - offset <= Self.maximumRead else { return .unavailable }
            try handle.seek(toOffset: offset - UInt64(anchor.count))
            if !anchor.isEmpty {
                guard try handle.read(upToCount: anchor.count) == anchor else { return .unavailable }
            }
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: Int(end - offset)) ?? Data()
            // Preserve subsequent receipt lines when a log write splits a UTF-8 character.
            // swiftlint:disable:next optional_data_string_conversion
            let text = String(decoding: data, as: UTF8.self)
            let accepted = text.contains("GameAction [AppID \(appID),")
                || text.contains("Game process added : AppID \(appID) ")
            return accepted ? .accepted : .waiting
        } catch { return .unavailable }
    }
}
