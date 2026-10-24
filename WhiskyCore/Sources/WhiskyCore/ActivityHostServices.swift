//
//  ActivityHostServices.swift
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

/// The birth token is opaque and follows the host's process identity convention.
/// It is platform-dependent (macOS: start time in microseconds; Linux: jiffies from
/// `/proc/<pid>/stat`). It is only meaningful for same-platform equality comparison and
/// must not be serialized into cross-platform protocols.
public struct HostProcessIdentity: Equatable, Sendable {
    public var pid: Int32
    public var birth: UInt64

    public init(pid: Int32, birth: UInt64) {
        self.pid = pid
        self.birth = birth
    }
}

public protocol ProcessIdentityProviding: Sendable {
    var currentProcess: HostProcessIdentity { get }
    func isAlive(_ process: HostProcessIdentity) -> Bool
}

/// The operation executes synchronously while the host holds its exclusive file lock.
public protocol ActivityFileLocking: Sendable {
    func withExclusiveLock<Result>(at url: URL, operation: () throws -> Result) throws -> Result
}
