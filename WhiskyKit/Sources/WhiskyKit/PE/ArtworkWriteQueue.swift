//
//  ArtworkWriteQueue.swift
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

/// Disposable derivatives use a bounded queue separate from image decoding.
final class ArtworkWriteQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.franke.Whisky.artwork-writer", qos: .utility)
    private let lock = NSLock()
    private var pending: [URL: IconCache.Sampled] = [:]
    private var running = false
    /// Accessed exclusively on queue.
    private var cache: ArtworkDiskCache

    init(cache: ArtworkDiskCache) {
        self.cache = cache
    }

    func enqueue(_ sampled: IconCache.Sampled, at url: URL) {
        lock.lock()
        if pending.count >= 16, let key = pending.keys.first {
            pending.removeValue(forKey: key)
        }
        pending[url] = sampled
        let start = !running
        running = true
        lock.unlock()
        if start {
            queue.async { self.drain() }
        }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let next = pending.popFirst() else {
                running = false
                lock.unlock()
                return
            }
            lock.unlock()
            cache.save(next.value, at: next.key)
        }
    }

    func remove(at url: URL) {
        queue.sync { try? FileManager.default.removeItem(at: url) }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}
