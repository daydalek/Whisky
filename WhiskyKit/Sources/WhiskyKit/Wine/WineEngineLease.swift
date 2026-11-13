//
//  WineEngineLease.swift
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

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import CryptoKit
import Foundation

/// Mutual exclusion between Wine operations and engine reselection, per
/// bottle prefix.
///
/// Every operation that resolves and runs an engine holds a *shared* lease on
/// the prefix for its whole lifetime — from engine resolution through process
/// exit. Engine reselection takes an *exclusive* lease before it even probes
/// busy state and keeps it until the new binding is persisted, so a rebind can
/// never observe or interrupt a half-prepared launch. Leases are nonblocking
/// `flock`s on app-owned lock files under the engine registry directory
/// (never inside the prefix or the engine tree), keyed by the canonical
/// prefix path — so they also exclude *other* Maltoria processes (the CLI,
/// a second app instance). Programs and wineservers run by anything that does
/// not take these leases — a terminal, another app — are outside this mutual
/// exclusion by definition.
public enum WineEngineLease {
    /// Directory holding the per-prefix lock files: `Engine Locks/` next to
    /// the engine registry.
    public static func lockDirectory(registryURL: URL) -> URL {
        registryURL.deletingLastPathComponent().appending(path: "Engine Locks")
    }

    /// Lock file for one prefix — the canonical path hashed into the name so
    /// the file stays inside the app-owned directory regardless of prefix
    /// location.
    public static func lockFile(prefixURL: URL, registryURL: URL) -> URL {
        let canonical = prefixURL.resolvingSymlinksInPath().standardizedFileURL
            .path(percentEncoded: false)
        let key = SHA256.hash(data: Data(canonical.utf8))
            .prefix(16).map { String(format: "%02x", $0) }.joined()
        return lockDirectory(registryURL: registryURL).appending(path: "\(key).lock")
    }

    /// Takes a nonblocking shared or exclusive lease on `prefixURL`.
    ///
    /// - Returns: The file descriptor holding the lock; pass it to
    ///   ``release(_:)``.
    /// - Throws: ``WineEngineError/operationBusy(_:)`` when another lease
    ///   conflicts — shared leases coexist, an outstanding exclusive lease
    ///   (a reselection in progress) or this shared lease held during an
    ///   exclusive attempt makes the acquisition fail fast.
    public static func acquire(
        prefixURL: URL, registryURL: URL, exclusive: Bool
    ) throws -> Int32 {
        let file = lockFile(prefixURL: prefixURL, registryURL: registryURL)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let descriptor = open(
            file.path(percentEncoded: false), O_RDWR | O_CREAT | O_CLOEXEC, 0o600
        )
        guard descriptor >= 0 else {
            throw WineEngineError.operationBusy(
                "Could not open the engine lease lock: \(file.path)"
            )
        }
        guard flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            close(descriptor)
            throw WineEngineError.operationBusy(
                exclusive
                    ? "A Wine operation is still running in this container"
                    : "An engine selection is in progress for this container"
            )
        }
        return descriptor
    }

    /// Releases a lease acquired by ``acquire(prefixURL:registryURL:exclusive:)``.
    public static func release(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    /// Exactly-once, thread-safe owner of a lease descriptor.
    ///
    /// Process streams hand a lease to whichever finishes last — the consumer
    /// ending iteration or the spawned process exiting — and both paths can
    /// race. The lock guarantees the fd is closed once and never reused after
    /// release; ``TaskLocal`` operation contexts retain the handle so a child
    /// task outliving its parent keeps the lease it inherited alive instead
    /// of operating on a recycled descriptor.
    public final class LeaseHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptor: Int32?

        init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        /// Releases the lease exactly once; later calls are no-ops.
        public func release() {
            lock.lock()
            let taken = descriptor
            descriptor = nil
            lock.unlock()
            if let taken {
                WineEngineLease.release(taken)
            }
        }

        deinit {
            release()
        }
    }

    /// ``acquire(prefixURL:registryURL:exclusive:)`` wrapped in the
    /// exactly-once ``LeaseHandle``.
    public static func acquireHandle(
        prefixURL: URL, registryURL: URL, exclusive: Bool
    ) throws -> LeaseHandle {
        try LeaseHandle(
            descriptor: acquire(prefixURL: prefixURL, registryURL: registryURL, exclusive: exclusive)
        )
    }
}
