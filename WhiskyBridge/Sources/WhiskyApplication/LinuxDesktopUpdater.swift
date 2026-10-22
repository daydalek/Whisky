//
//  LinuxDesktopUpdater.swift
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

import Foundation
import WhiskyBridgeProtocol

enum LinuxDesktopUpdater {
    struct Status {
        let installed: Bool
        let needsUpdate: Bool
    }

    static func status(_ contents: String, at target: URL, arguments: [[String]], handlesFiles: Bool) throws -> Status {
        guard FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path) else {
            return Status(installed: false, needsUpdate: false)
        }
        return try withTarget(target) { target in
            try DesktopUpdateTransaction.recover(target)
            guard try DesktopFileIdentity.read(target) != nil
            else { return Status(installed: false, needsUpdate: false) }
            let existing = try DesktopFileSnapshot.read(target)
            let merged = try DesktopEntryUpdate.merge(
                existing.data,
                desired: contents,
                arguments: arguments,
                handlesFiles: handlesFiles
            )
            return Status(installed: merged == existing.data, needsUpdate: merged != existing.data)
        }
    }

    @discardableResult static func publish(
        _ contents: String, at target: URL, arguments: [[String]], handlesFiles: Bool
    ) throws -> Bool {
        try withTarget(target) { target in
            try DesktopUpdateTransaction.recover(target)
            guard try DesktopFileIdentity.read(target) != nil else {
                try LinuxDesktopEntry.publish(contents, at: target)
                return false
            }
            let existing = try DesktopFileSnapshot.read(target)
            let merged = try DesktopEntryUpdate.merge(
                existing.data,
                desired: contents,
                arguments: arguments,
                handlesFiles: handlesFiles
            )
            guard existing.data != merged else { return false }
            let record = try DesktopUpdateTransaction.prepare(existing, contents: merged, target: target)
            do { try record.perform() } catch {
                do { try DesktopUpdateTransaction.recover(target) } catch {
                    throw BridgeFailure(
                        "desktop_update_recovery",
                        "Desktop update retained recovery files: " +
                            DesktopUpdateTransaction.location(target).path
                    )
                }
                throw error
            }
            return true
        }
    }

    private static func withTarget<T>(_ requested: URL, operation: (URL) throws -> T) throws -> T {
        let parent = ContainerRegistry.canonical(requested.deletingLastPathComponent())
        let target = parent.appendingPathComponent(requested.lastPathComponent)
        let lease = try ContainerRegistry.acquire(ApplicationWorkspace(registry: target))
        defer { ContainerRegistry.release(lease) }
        return try operation(target)
    }
}
