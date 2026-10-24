//
//  MacOSActivityHostServices.swift
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
import WhiskyCore

public struct MacOSProcessIdentity: ProcessIdentityProviding {
    public init() {}

    public var currentProcess: HostProcessIdentity {
        HostProcessIdentity(pid: getpid(), birth: currentProcessBirth())
    }

    private func currentProcessBirth() -> UInt64 {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        if size == MemoryLayout<proc_bsdinfo>.size {
            return UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
        }
        return 0
    }

    public func isAlive(_ process: HostProcessIdentity) -> Bool {
        let pid = process.pid
        let birth = process.birth
        guard pid > 0 else { return false }
        if kill(pid, 0) != 0 {
            return errno == EPERM
        }
        guard birth > 0 else { return true }
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard size == MemoryLayout<proc_bsdinfo>.size else { return false }
        let actualBirth = UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
        return actualBirth == birth
    }
}

public struct MacOSActivityFileLock: ActivityFileLocking {
    public init() {}

    public func withExclusiveLock<Result>(at url: URL, operation: () throws -> Result) throws -> Result {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path(percentEncoded: false), O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        var lockResult: Int32 = -1
        repeat {
            lockResult = flock(descriptor, LOCK_EX)
        } while lockResult != 0 && errno == EINTR
        guard lockResult == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try operation()
    }
}

public extension GameActivityOwner {
    init(
        source: Source, ownerID: UUID = UUID(), hostPID: pid_t = getpid(),
        hostProcessBirth: UInt64 = GameActivityStore.currentProcessBirth(), generation: UInt64 = 1
    ) {
        self.init(
            source: source, ownerID: ownerID,
            process: HostProcessIdentity(pid: hostPID, birth: hostProcessBirth), generation: generation
        )
    }
}
