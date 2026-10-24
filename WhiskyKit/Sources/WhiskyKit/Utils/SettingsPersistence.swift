//
//  SettingsPersistence.swift
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

import Foundation
import os.log

/// Coalesces atomic settings writes on a serial utility queue. Flush at handoff boundaries.
public final class SettingsPersistence: @unchecked Sendable {
    public static let shared = SettingsPersistence(backgroundWritesEnabled: false)
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.franke.Whisky.settings-writer", qos: .utility)
    private struct Stamp: Equatable {
        let inode: UInt64
        let modified: Date
        let size: UInt64
    }

    private struct Pending {
        let data: Data
        let expected: Stamp?
    }

    private var pending: [URL: Pending] = [:]
    // Accessed exclusively by queue.
    private var written: [URL: Stamp] = [:]
    private var scheduled = false
    private var backgroundWritesEnabled: Bool

    init(backgroundWritesEnabled: Bool = true) {
        self.backgroundWritesEnabled = backgroundWritesEnabled
    }

    /// GUI editing enables coalescing; command-line tools retain synchronous persistence.
    public func enableBackgroundWrites() {
        lock.lock()
        backgroundWritesEnabled = true
        lock.unlock()
    }

    func enqueue(_ data: Data, to url: URL) {
        let snapshot = Pending(data: data, expected: Self.stamp(url))
        lock.lock()
        pending[url] = snapshot
        let background = backgroundWritesEnabled
        let needsSchedule = background && !scheduled
        scheduled = background
        lock.unlock()
        if !background {
            flush(for: url)
        } else if needsSchedule {
            queue.asyncAfter(deadline: .now() + .milliseconds(100)) { self.drain() }
        }
    }

    /// Makes accepted edits visible to synchronous readers, CLI handoffs and filesystem moves.
    public func flush() {
        queue.sync { self.drain() }
    }

    func flush(for url: URL) {
        queue.sync {
            self.lock.lock()
            let data = self.pending.removeValue(forKey: url)
            self.lock.unlock()
            if let data {
                self.write(data, to: url)
            }
        }
    }

    private func drain() {
        lock.lock()
        let writes = pending
        pending.removeAll()
        scheduled = false
        lock.unlock()
        for (url, data) in writes {
            write(data, to: url)
        }
    }

    private static func stamp(_ url: URL) -> Stamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber
        else { return nil }
        return Stamp(inode: inode.uint64Value, modified: modified, size: size.uint64Value)
    }

    private func write(_ pending: Pending, to url: URL) {
        let current = Self.stamp(url)
        // A newer external writer owns its replacement; later local edits get a fresh baseline.
        guard current == pending.expected || current == written[url] else { return }
        do {
            try pending.data.write(to: url, options: .atomic)
            written[url] = Self.stamp(url)
        } catch {
            Logger.wineKit.error("Failed to save settings at \(url.path): \(error)")
        }
    }
}
