//
//  RuntimeEventChannel.swift
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

/// Subscribers receive independent queues; cancelling one consumer releases its queue.
@MainActor
public final class RuntimeEventChannel<Event: Sendable> {
    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]
    public init() {}

    public func stream(replaying events: [Event] = []) -> AsyncStream<Event> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        continuations[id] = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { @MainActor in self?.continuations[id] = nil }
        }
        for event in events {
            continuation.yield(event)
        }
        return stream
    }

    public func send(_ event: Event) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    public func finish() {
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    deinit {
        for continuation in continuations.values {
            continuation.finish()
        }
    }
}
