//
//  DurableAtomicFile.swift
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

/// Checked publication with stable, separately held lock files at the call sites.
enum DurableAtomicFile {
    static func remove(_ url: URL) throws {
        guard unlink(url.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
        if directory >= 0 {
            defer { close(directory) }
            _ = fsync(directory)
        }
    }

    static func write(_ data: Data, to url: URL, mode: mode_t = 0o600, immutable: Bool = false) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        let descriptor = open(temporary.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        guard fchmod(descriptor, mode) == 0, fsync(descriptor) == 0 else { throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno)
        ) }
        if immutable {
            if link(temporary.path, url.path) != 0 {
                guard errno == EEXIST, try Data(contentsOf: url) == data else { throw CocoaError(.fileWriteFileExists) }
            }
        } else {
            guard rename(temporary.path, url.path) == 0 else { throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno)
            ) }
        }
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
        if directory >= 0 {
            defer { close(directory) }
            _ = fsync(directory)
        }
    }
}
