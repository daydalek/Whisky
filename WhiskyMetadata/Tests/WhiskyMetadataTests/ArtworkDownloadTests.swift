//
//  ArtworkDownloadTests.swift
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
import Testing
@testable import WhiskyMetadata
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private let artworkTestBytes = Data(base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAYAAAB/qH1jAAAAEklEQVR4nGP43+HyHxkzoAsAAHyRFlERVA2OAAAAAElFTkSuQmCC"
) ?? Data()

@Test func queuedCoverRequestChecksOfflinePolicyBeforeStartingHTTP() async throws {
    let gate = CoverRequestGate()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-queued-offline-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [GatedCoverProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let policy = ToggleNetworkPolicy()
    let store = GameMetadataStore(directory: root, networkAccess: { try policy.check() })
    let urls = try (0 ..< 5).map { _ in
        try #require(URL(string: "https://queued.example/\(UUID()).png"))
    }
    GatedCoverProtocol.install(gate, for: urls.map { $0.path })
    defer { GatedCoverProtocol.remove(paths: urls.map { $0.path }) }

    let tasks = urls.map { url in
        Task { try? await store.cacheCover(from: url, session: session) }
    }
    await gate.waitForStarts(4)
    policy.setOffline()
    gate.release(4)
    for task in tasks {
        await task.value
    }

    #expect(GatedCoverProtocol.totalCount(for: urls.map { $0.path }) == 4)
    #expect(urls.filter { store.cachedCoverURL(for: $0) != nil }.count == 4)
}

@Test func cancelingOneCoverConsumerLeavesTheSharedDownloadForAnother() async throws {
    let gate = CoverRequestGate()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-cancel-one-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [GatedCoverProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let remote = try #require(URL(string: "https://cancel.example/\(UUID()).png"))
    let barrier = NetworkAccessBarrier()
    let store = GameMetadataStore(directory: root, networkAccess: { await barrier.check() })
    GatedCoverProtocol.install(gate, for: [remote.path])
    defer { GatedCoverProtocol.remove(paths: [remote.path]) }

    let canceled = Task { try await store.cacheCover(from: remote, session: session) }
    let remaining = Task { try await store.cacheCover(from: remote, session: session) }
    await gate.waitForStarts(1)
    canceled.cancel()
    await #expect(throws: CancellationError.self) { try await canceled.value }
    gate.release(1)
    try await remaining.value

    #expect(GatedCoverProtocol.totalCount(for: [remote.path]) == 1)
    #expect(store.cachedCoverURL(for: remote) != nil)
}

@Test func cancelingLastCoverConsumerStopsWorkerWithoutPublishingCache() async throws {
    let gate = CoverRequestGate()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-cancel-last-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [GatedCoverProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let remote = try #require(URL(string: "https://cancel.example/\(UUID()).png"))
    let store = GameMetadataStore(directory: root, networkAccess: {})
    GatedCoverProtocol.install(gate, for: [remote.path])
    defer { GatedCoverProtocol.remove(paths: [remote.path]) }

    let canceled = Task { try await store.cacheCover(from: remote, session: session) }
    await gate.waitForStarts(1)
    canceled.cancel()
    await #expect(throws: CancellationError.self) { try await canceled.value }
    #expect(store.cachedCoverURL(for: remote) == nil)
    gate.release(1)
    #expect(store.cachedCoverURL(for: remote) == nil)
}

private actor NetworkAccessBarrier {
    private var calls = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func check() async {
        calls += 1
        guard calls < 2 else {
            waiters.forEach { $0.resume() }
            waiters.removeAll()
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private final class CoverRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var started = 0
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var releases = 0
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStart() {
        let ready = lock.withLock {
            started += 1
            let ready = startWaiters.filter { $0.0 <= started }
            startWaiters.removeAll { $0.0 <= started }
            return ready
        }
        ready.forEach { $0.1.resume() }
    }

    func waitForStarts(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if started >= count { return true }
                startWaiters.append((count, continuation))
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    func waitForRelease() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                guard releases == 0 else {
                    releases -= 1
                    return true
                }
                releaseWaiters.append(continuation)
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    func release(_ count: Int) {
        let ready = lock.withLock {
            let ready = Array(releaseWaiters.prefix(count))
            releaseWaiters.removeFirst(ready.count)
            releases += count - ready.count
            return ready
        }
        ready.forEach { $0.resume() }
    }
}

private final class ToggleNetworkPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var online = true

    func setOffline() {
        lock.withLock { online = false }
    }

    func check() throws {
        guard lock.withLock({ online }) else {
            throw URLError(.notConnectedToInternet)
        }
    }
}

private final class GatedCoverProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var gates: [String: CoverRequestGate] = [:]
    private nonisolated(unsafe) static var counts: [String: Int] = [:]
    private let responseLock = NSLock()
    private var gatedResponse: GatedCoverResponse?

    static func install(_ gate: CoverRequestGate, for paths: [String]) {
        lock.withLock {
            for path in paths {
                gates[path] = gate
                counts[path] = 0
            }
        }
    }

    static func remove(paths: [String]) {
        lock.withLock {
            for path in paths {
                gates[path] = nil
                counts[path] = nil
            }
        }
    }

    static func totalCount(for paths: [String]) -> Int {
        lock.withLock { paths.reduce(0) { $0 + counts[$1, default: 0] } }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let path = request.url?.path else { return }
        let gate = Self.lock.withLock {
            Self.counts[path, default: 0] += 1
            return Self.gates[path]
        }
        gate?.markStart()
        let response = GatedCoverResponse(protocolInstance: self, client: client, request: request)
        responseLock.withLock { gatedResponse = response }
        Task {
            await gate?.waitForRelease()
            response.send()
        }
    }

    override func stopLoading() {
        responseLock.withLock { gatedResponse }?.cancel()
    }
}

private final class GatedCoverResponse: @unchecked Sendable {
    private let lock = NSLock()
    private let protocolInstance: URLProtocol
    private let client: URLProtocolClient?
    private let request: URLRequest
    private var stopped = false
    private var sent = false

    init(protocolInstance: URLProtocol, client: URLProtocolClient?, request: URLRequest) {
        self.protocolInstance = protocolInstance
        self.client = client
        self.request = request
    }

    func cancel() {
        lock.withLock { stopped = true }
    }

    func send() {
        let shouldSend = lock.withLock {
            guard !stopped, !sent else { return false }
            sent = true
            return true
        }
        guard shouldSend else { return }
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"]
              )
        else { return }
        client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(protocolInstance, didLoad: artworkTestBytes)
        client?.urlProtocolDidFinishLoading(protocolInstance)
    }
}
