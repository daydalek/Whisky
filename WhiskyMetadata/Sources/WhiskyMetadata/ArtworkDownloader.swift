//
//  ArtworkDownloader.swift
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
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct ArtworkDownloadRecord {
    let generation: UUID
    let worker: Task<Void, Never>
    var consumers: [UUID: CheckedContinuation<Void, any Error>] = [:]
}

struct ArtworkRateLimitError: Error, Sendable {
    let statusCode: Int
    let retryAfter: TimeInterval
}

struct ArtworkHostCooldown: Sendable {
    let statusCode: Int
    let until: Date
}

actor ArtworkTransportLimiter {
    static let shared = ArtworkTransportLimiter(minInterval: 0.25)

    private static let maximumTrackedHosts = 256

    private let minInterval: TimeInterval
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var nextRequestAt: [String: Date] = [:]
    private var hostCooldowns: [String: ArtworkHostCooldown] = [:]
    private var activeHosts: [String: Int] = [:]

    init(minInterval: TimeInterval) {
        self.minInterval = minInterval
    }

    func download(
        host: String,
        operation: @Sendable () async throws -> Data
    ) async throws -> Data {
        activeHosts[host, default: 0] += 1
        defer {
            if let count = activeHosts[host], count > 1 {
                activeHosts[host] = count - 1
            } else {
                activeHosts[host] = nil
            }
            prune(now: Date(), preservingHost: host)
        }
        prune(now: Date())
        try enforceCooldown(for: host)
        try await acquire()
        defer { release() }
        try enforceCooldown(for: host)
        let now = Date()
        let start = max(now, nextRequestAt[host] ?? now)
        nextRequestAt[host] = start.addingTimeInterval(minInterval)
        let delay = start.timeIntervalSince(now)
        if delay > 0 {
            try await Task.sleep(for: .seconds(delay))
        }
        try Task.checkCancellation()
        try enforceCooldown(for: host)
        do {
            return try await operation()
        } catch let error as ArtworkRateLimitError {
            extendCooldown(for: host, with: error)
            throw error
        }
    }

    private func enforceCooldown(for host: String) throws {
        guard let cooldown = hostCooldowns[host] else { return }
        let retryAfter = cooldown.until.timeIntervalSinceNow
        guard retryAfter > 0 else {
            hostCooldowns[host] = nil
            return
        }
        throw ArtworkRateLimitError(statusCode: cooldown.statusCode, retryAfter: retryAfter)
    }

    private func extendCooldown(for host: String, with error: ArtworkRateLimitError) {
        let until = Date().addingTimeInterval(max(30, error.retryAfter))
        guard hostCooldowns[host].map({ $0.until < until }) ?? true else { return }
        hostCooldowns[host] = ArtworkHostCooldown(statusCode: error.statusCode, until: until)
    }

    private func prune(now: Date, preservingHost hostToKeep: String? = nil) {
        hostCooldowns = hostCooldowns.filter { $0.value.until > now }
        nextRequestAt = nextRequestAt.filter { $0.value > now }

        let cooldownExcess = hostCooldowns.count - Self.maximumTrackedHosts
        if cooldownExcess > 0 {
            let removable = hostCooldowns
                .filter { activeHosts[$0.key] == nil && $0.key != hostToKeep }
                .sorted { $0.value.until < $1.value.until }
            for (host, _) in removable.prefix(cooldownExcess) {
                hostCooldowns[host] = nil
            }
        }

        let pacingExcess = nextRequestAt.count - Self.maximumTrackedHosts
        if pacingExcess > 0 {
            let removable = nextRequestAt
                .filter { activeHosts[$0.key] == nil && $0.key != hostToKeep }
                .sorted { $0.value < $1.value }
            for (host, _) in removable.prefix(pacingExcess) {
                nextRequestAt[host] = nil
            }
        }
    }

    private func acquire() async throws {
        if active >= 4 {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            active += 1
        }
        do {
            try Task.checkCancellation()
        } catch {
            release()
            throw error
        }
    }

    private func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            active -= 1
        }
    }
}

final class ArtworkDataLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let maximumBytes = 15 * 1_024 * 1_024

    private struct State {
        let continuation: CheckedContinuation<Data, any Error>
        let session: URLSession
        let task: URLSessionDataTask
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var data = Data()
    private var cancelled = false

    static func download(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> Data {
        let loader = ArtworkDataLoader()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                loader.start(request, configuration: configuration, continuation: continuation)
            }
        } onCancel: {
            loader.cancel()
        }
    }

    private func start(
        _ request: URLRequest,
        configuration: URLSessionConfiguration,
        continuation: CheckedContinuation<Data, any Error>
    ) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        self.session = session
        self.task = task
        lock.unlock()
        task.resume()
    }

    private func cancel() {
        lock.withLock { cancelled = true }
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Data, any Error>) {
        let state: State? = lock.withLock {
            guard let continuation, let session, let task else { return nil }
            self.continuation = nil
            self.session = nil
            self.task = nil
            return State(continuation: continuation, session: session, task: task)
        }
        guard let state else { return }
        state.task.cancel()
        state.session.invalidateAndCancel()
        state.continuation.resume(with: result)
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard request.url?.scheme == "https" else {
            completionHandler(nil)
            finish(.failure(URLError(.unsupportedURL)))
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard response.url?.scheme == "https",
              let http = response as? HTTPURLResponse
        else {
            completionHandler(.cancel)
            finish(.failure(URLError(.unsupportedURL)))
            return
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            completionHandler(.cancel)
            if http.statusCode == 429 || http.statusCode == 503 {
                finish(.failure(ArtworkRateLimitError(
                    statusCode: http.statusCode,
                    retryAfter: PublicGameMetadataProvider.parseRetryAfter(
                        http.value(forHTTPHeaderField: "Retry-After")
                    ) ?? 30
                )))
            } else {
                finish(.failure(ProviderError.http(http.statusCode)))
            }
            return
        }
        guard response.mimeType?.hasPrefix("image/") == true,
              response.expectedContentLength <= Int64(Self.maximumBytes)
              || response.expectedContentLength == NSURLSessionTransferSizeUnknown
        else {
            completionHandler(.cancel)
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive chunk: Data) {
        let accepted = lock.withLock {
            guard data.count <= Self.maximumBytes - chunk.count else { return false }
            data.append(chunk)
            return true
        }
        if !accepted {
            finish(.failure(URLError(.dataLengthExceedsMaximum)))
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            finish(.failure(error))
        } else {
            let data = lock.withLock { self.data }
            if data.isEmpty {
                finish(.failure(URLError(.zeroByteResource)))
            } else {
                finish(.success(data))
            }
        }
    }
}
