//
//  DesktopUpdateTransaction.swift
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

/// A retired entry is retained until exclusive publication of the replacement completes.
struct DesktopUpdateTransaction: Codable {
    let version: Int
    let id: UUID
    let target: URL
    let previous: URL
    let next: URL
    let oldIdentity: DesktopFileIdentity
    let newIdentity: DesktopFileIdentity
    let oldData: Data
    let newData: Data

    static func location(_ target: URL) -> URL {
        target.appendingPathExtension("whisky-update.plist")
    }

    static func prepare(_ snapshot: DesktopFileSnapshot, contents: Data, target: URL) throws -> Self {
        guard contents.count <= 65_536 else { throw DesktopEntryUpdate.modified() }
        let id = UUID()
        let next = target.deletingLastPathComponent().appendingPathComponent(".whisky-desktop-next-" + id.uuidString)
        let previous = target.deletingLastPathComponent()
            .appendingPathComponent(".whisky-desktop-previous-" + id.uuidString)
        let descriptor = open(next.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, mode_t(snapshot.mode))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        do {
            guard fchmod(descriptor, mode_t(snapshot.mode)) == 0 else { throw POSIXError(.EIO) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            try handle.write(contentsOf: contents)
            try handle.synchronize()
            let identity = try DesktopFileSnapshot.read(next).identity
            let record = Self(
                version: 1,
                id: id,
                target: target,
                previous: previous,
                next: next,
                oldIdentity: snapshot.identity,
                newIdentity: identity,
                oldData: snapshot.data,
                newData: contents
            )
            try ContainerJournal.publish(PropertyListEncoder().encode(record), at: location(target), replace: false)
            return record
        } catch {
            _ = unlink(next.path)
            throw error
        }
    }

    func perform() throws {
        let error = whisky_host_move(target.path, previous.path)
        guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
        let captured = try DesktopFileSnapshot.read(previous)
        guard captured.identity == oldIdentity, captured.data == oldData else { throw DesktopEntryUpdate.modified() }
        let replacement = try DesktopFileSnapshot.read(next)
        guard replacement.identity == newIdentity, replacement.data == newData else { throw conflict() }
        guard link(next.path, target.path) == 0 else { throw DesktopEntryUpdate.foreign() }
        try cleanupCommitted()
    }

    func cleanupCommitted() throws {
        guard try DesktopFileIdentity.read(target) == newIdentity else { throw conflict() }
        if try DesktopFileIdentity.read(previous) != nil {
            let backup = try DesktopFileSnapshot.read(previous)
            guard backup.identity == oldIdentity, backup.data == oldData else { throw conflict() }
            guard unlink(previous.path) == 0 else { throw POSIXError(.EIO) }
        }
        try removeNext(requireData: false)
        guard unlink(Self.location(target).path) == 0 else { throw POSIXError(.EIO) }
    }

    private func removeNext(requireData: Bool = true) throws {
        guard let identity = try DesktopFileIdentity.read(next) else { return }
        guard identity == newIdentity else { throw conflict() }
        if requireData {
            let staging = try DesktopFileSnapshot.read(next)
            guard staging.data == newData else { throw conflict() }
        }
        guard unlink(next.path) == 0 else { throw POSIXError(.EIO) }
    }

    static func recover(_ target: URL) throws {
        guard try DesktopFileIdentity.read(location(target)) != nil else { return }
        let snapshot = try DesktopFileSnapshot.read(location(target), limit: 262_144)
        guard snapshot.data.count <= 262_144 else { throw DesktopEntryUpdate.modified() }
        let record = try PropertyListDecoder().decode(Self.self, from: snapshot.data)
        try record.validate(target)
        if try DesktopFileIdentity.read(target) == record.newIdentity {
            try record.cleanupCommitted()
            return
        }
        let current = try DesktopFileIdentity.read(target)
        let backup = try DesktopFileIdentity.read(record.previous)
        if current == nil, backup != nil {
            let error = whisky_host_move(record.previous.path, target.path)
            guard error == 0 else { throw record.conflict() }
        } else if backup != nil {
            throw record.conflict()
        }
        try record.removeNext()
        guard unlink(location(target).path) == 0 else { throw POSIXError(.EIO) }
    }

    private func validate(_ expected: URL) throws {
        guard version == 1, target.path == expected.path,
              previous.path == target.deletingLastPathComponent()
              .appendingPathComponent(".whisky-desktop-previous-" + id.uuidString).path,
              next.path == target.deletingLastPathComponent()
              .appendingPathComponent(".whisky-desktop-next-" + id.uuidString).path,
              oldIdentity.kind == 2, newIdentity.kind == 2, oldData.count <= 65_536, newData.count <= 65_536
        else {
            throw conflict()
        }
    }

    private func conflict() -> BridgeFailure {
        BridgeFailure("desktop_update_recovery", "Preserve the desktop entry and its recovery files: " + previous.path)
    }
}
