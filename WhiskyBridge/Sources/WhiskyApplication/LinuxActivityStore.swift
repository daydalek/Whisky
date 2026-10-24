//
//  LinuxActivityStore.swift
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
import WhiskyCore

/// Uses the same leases, filenames and sample tokens as the native tracker.
@MainActor
final class LinuxActivityStore {
    private let ownerID = UUID()
    private var sequence: UInt64 = 0
    private var pending: [String: TimeInterval] = [:]

    func sample(_ entry: LibraryEntry, seconds: TimeInterval, at date: Date, completed: Bool = false) throws {
        guard !entry.isLauncher else { return }
        let url = LibraryStorageLayout.activity(for: entry)
        let key = url.path
        pending[key, default: 0] += seconds
        let amount = pending[key] ?? 0
        let identity = HostProcessIdentityProvider()
        do {
            try HostFileLock().withExclusiveLock(at: url.deletingPathExtension().appendingPathExtension("lock")) {
                var activity = FileManager.default.fileExists(atPath: url.path)
                    ? try JSONDecoder().decode(GameActivity.self, from: Data(contentsOf: url)) : GameActivity()
                let owner = try activity.acquireOwnership(
                    source: .gui,
                    ownerID: ownerID,
                    process: identity.currentProcess,
                    isAlive: identity.isAlive
                )
                let token = GameActivitySampleToken(ownerID: ownerID, generation: owner.generation, sequence: sequence)
                _ = activity.recordSample(seconds: amount, at: date, token: token)
                if completed {
                    activity.completeSession(at: date, ownerID: ownerID, generation: owner.generation)
                }
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try JSONEncoder().encode(activity).write(to: url, options: .atomic)
            }
            sequence &+= 1
            pending[key] = nil
        } catch is GameActivityOwnershipError {
            // A different live frontend owns these observations and records this interval.
            pending[key] = nil
        }
    }

    func release(_ entry: LibraryEntry) throws {
        let url = LibraryStorageLayout.activity(for: entry)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try HostFileLock().withExclusiveLock(at: url.deletingPathExtension().appendingPathExtension("lock")) {
            var activity = try JSONDecoder().decode(GameActivity.self, from: Data(contentsOf: url))
            guard let owner = activity.owner, owner.ownerID == ownerID else { return }
            activity.releaseOwnership(ownerID: ownerID, generation: owner.generation)
            try JSONEncoder().encode(activity).write(to: url, options: .atomic)
        }
    }
}
