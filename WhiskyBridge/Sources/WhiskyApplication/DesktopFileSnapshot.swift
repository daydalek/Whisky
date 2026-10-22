//
//  DesktopFileSnapshot.swift
//  WhiskyApplication
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

import CHostCommand
import Foundation
import WhiskyBridgeProtocol
#if os(Linux)
import Glibc
#elseif os(macOS)
import Darwin
#endif

struct DesktopFileIdentity: Codable, Equatable {
    let device: UInt64
    let inode: UInt64
    let kind: Int32

    static func read(_ url: URL) throws -> Self? {
        var device: UInt64 = 0, inode: UInt64 = 0
        var kind: Int32 = 0
        let error = whisky_host_identity(url.path, &device, &inode, &kind)
        if error == ENOENT || error == ENOTDIR {
            return nil
        }
        guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
        return Self(device: device, inode: inode, kind: kind)
    }
}

struct DesktopFileSnapshot {
    let identity: DesktopFileIdentity
    let data: Data
    let mode: UInt32

    static func read(_ url: URL, limit: Int = 65_536) throws -> Self {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw DesktopEntryUpdate.foreign() }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid()
        else { throw DesktopEntryUpdate.foreign() }
        let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            .read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw DesktopEntryUpdate.modified() }
        return Self(
            identity: DesktopFileIdentity(
                device: UInt64(truncatingIfNeeded: status.st_dev),
                inode: UInt64(status.st_ino),
                kind: 2
            ),
            data: data,
            mode: UInt32(status.st_mode & 0o777)
        )
    }
}
