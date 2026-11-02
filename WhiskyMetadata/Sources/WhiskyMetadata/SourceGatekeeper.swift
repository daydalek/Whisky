//
//  SourceGatekeeper.swift
//  WhiskyMetadata
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

/// Serializes requests per source, caches recent queries/details, paces burst traffic,
/// and honors HTTP 429/503 Retry-After cooldowns so batch syncs do not hammer sites.
public actor SourceGatekeeper {
    private static let bangumi = SourceGatekeeper(minInterval: 0.25)
    private static let vndb = SourceGatekeeper(minInterval: 0.25)
    private static let steam = SourceGatekeeper(minInterval: 0.25)
    private static let fallback = SourceGatekeeper(minInterval: 0)
    private static let bangumiTransport = SourceGatekeeper(minInterval: 0.25)
    private static let vndbTransport = SourceGatekeeper(minInterval: 0.25)
    private static let steamTransport = SourceGatekeeper(minInterval: 0.25)
    private static let fallbackTransport = SourceGatekeeper(minInterval: 0)

    static func shared(for source: GameMetadataSource) -> SourceGatekeeper {
        switch source {
        case .bangumi: bangumi
        case .vndb: vndb
        case .steam: steam
        case .ymgal, .hikarinagi, .nextmoe: fallback
        }
    }

    static func sharedTransport(for source: GameMetadataSource) -> SourceGatekeeper {
        switch source {
        case .bangumi: bangumiTransport
        case .vndb: vndbTransport
        case .steam: steamTransport
        case .ymgal, .hikarinagi, .nextmoe: fallbackTransport
        }
    }

    private let minInterval: TimeInterval
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var searches: [String: (Date, [GameMetadata])] = [:]
    private var gameDetails: [String: (Date, GameMetadata)] = [:]
    private var characterResults: [String: (Date, [GameCharacter])] = [:]
    private var characterFailures: [String: (Date, Error)] = [:]
    private var lastRequestAt: Date?
    private var cooldownUntil: (date: Date, code: Int)?

    public init(minInterval: TimeInterval) {
        self.minInterval = minInterval
    }

    private func acquire() async throws {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        do { try Task.checkCancellation() } catch { release()
            throw error
        }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    private func paceAndCheckCooldown() async throws {
        if let cooldown = cooldownUntil {
            if Date() < cooldown.date {
                throw ProviderError.http(cooldown.code)
            }
            cooldownUntil = nil
        }
        if minInterval > 0, let last = lastRequestAt {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < minInterval {
                try await Task.sleep(for: .milliseconds(Int((minInterval - elapsed) * 1_000)))
            }
        }
    }

    private func recordRateLimit(_ code: Int, retryAfter: TimeInterval?) {
        let delay = retryAfter ?? (minInterval > 0 ? 15.0 : 0)
        if delay > 0 {
            cooldownUntil = (Date().addingTimeInterval(delay), code)
        }
    }

    public func search(
        _ key: String,
        operation: @Sendable () async throws -> [GameMetadata]
    ) async throws -> [GameMetadata] {
        try await acquire()
        defer { release() }
        let now = Date()
        if let cached = searches[key], now.timeIntervalSince(cached.0) < 300 {
            return cached.1
        }
        try await paceAndCheckCooldown()
        defer { lastRequestAt = Date() }
        do {
            let results = try await operation()
            Self.insertCache(results, forKey: key, into: &searches, ttl: 300, limit: 64)
            return results
        } catch let ProviderError.rateLimited(code, retryAfter) {
            recordRateLimit(code, retryAfter: retryAfter)
            throw ProviderError.http(code)
        }
    }

    public func details(
        _ id: String,
        operation: @Sendable () async throws -> GameMetadata
    ) async throws -> GameMetadata {
        try await acquire()
        defer { release() }
        let now = Date()
        if let cached = gameDetails[id], now.timeIntervalSince(cached.0) < 600 {
            return cached.1
        }
        try await paceAndCheckCooldown()
        defer { lastRequestAt = Date() }
        do {
            let result = try await operation()
            Self.insertCache(result, forKey: id, into: &gameDetails, ttl: 600, limit: 100)
            return result
        } catch let ProviderError.rateLimited(code, retryAfter) {
            recordRateLimit(code, retryAfter: retryAfter)
            throw ProviderError.http(code)
        }
    }

    /// A serialized, paced operation whose result belongs to the caller's local store.
    public func paced<T: Sendable>(operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        try await paceAndCheckCooldown()
        defer { lastRequestAt = Date() }
        do {
            return try await operation()
        } catch let ProviderError.rateLimited(code, retryAfter) {
            recordRateLimit(code, retryAfter: retryAfter)
            throw ProviderError.http(code)
        }
    }

    public func characters(
        _ id: String,
        operation: @Sendable () async throws -> [GameCharacter]
    ) async throws -> [GameCharacter] {
        try await acquire()
        defer { release() }
        if let cached = characterResults[id], Date().timeIntervalSince(cached.0) < 600 {
            return cached.1
        }
        if let failed = characterFailures[id], Date().timeIntervalSince(failed.0) < 30 {
            throw failed.1
        }
        try await paceAndCheckCooldown()
        defer { lastRequestAt = Date() }
        do {
            let result = try await operation()
            Self.insertCache(result, forKey: id, into: &characterResults, ttl: 600, limit: 100)
            characterFailures[id] = nil
            return result
        } catch let ProviderError.rateLimited(code, retryAfter) {
            recordRateLimit(code, retryAfter: retryAfter)
            throw ProviderError.http(code)
        } catch {
            if !Task.isCancelled {
                Self.insertCache(error, forKey: id, into: &characterFailures, ttl: 30, limit: 100)
            }
            throw error
        }
    }

    static func insertCache<Value>(
        _ value: Value, forKey key: String, into cache: inout [String: (Date, Value)],
        ttl: TimeInterval, limit: Int
    ) {
        let now = Date()
        if cache.count >= limit {
            cache = cache.filter { now.timeIntervalSince($0.value.0) < ttl }
            if cache.count >= limit, let oldestKey = cache.min(by: { $0.value.0 < $1.value.0 })?.key {
                cache.removeValue(forKey: oldestKey)
            }
        }
        cache[key] = (now, value)
    }
}
