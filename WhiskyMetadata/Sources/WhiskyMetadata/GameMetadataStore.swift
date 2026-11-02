//
//  GameMetadataStore.swift
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
import WhiskyCore

/// Separate from ProgramSettings: attaching or removing artwork cannot change a launch.
/// The caller supplies a bottle-relative identity so moving a bottle preserves metadata.
public actor GameMetadataStore {
    private let directory: URL
    private let networkAccess: MetadataNetworkAccess
    private var artworkDownloads: [URL: Task<Void, any Error>] = [:]
    private var artworkFailures: [URL: Date] = [:]
    private var artworkLimiters: [ObjectIdentifier: ArtworkTransportLimiter] = [:]

    public init(directory: URL, networkAccess: @escaping MetadataNetworkAccess) {
        self.networkAccess = networkAccess
        self.directory = directory
    }

    public func loadCoverSettings(for identity: String) throws -> GameCoverSettings {
        let url = coverSettingsLocation(for: identity)
        guard FileManager.default.fileExists(atPath: url.path) else { return GameCoverSettings() }
        return try JSONDecoder().decode(GameCoverSettings.self, from: Data(contentsOf: url))
    }

    public func coverAspectRatio(for identity: String, metadataCoverURL: URL?) throws -> Double? {
        let settings = try loadCoverSettings(for: identity)
        let custom = settings.useCustomCover ? customCoverURL(for: settings) : nil
        let url = custom ?? metadataCoverURL.flatMap { cachedCoverURL(for: $0) }
        guard let url, let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let dimensions = MetadataImage.dimensions(data, validatePixels: false)
        else { return nil }
        return Double(dimensions.width) / Double(dimensions.height)
    }

    public func saveCoverSettings(_ settings: GameCoverSettings, for identity: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: coverSettingsLocation(for: identity), options: .atomic)
    }

    /// Own the imported bytes so the user's original file can move independently.
    public func importCover(_ data: Data, for identity: String) throws -> GameCoverSettings {
        guard data.count <= 30 * 1_024 * 1_024,
              MetadataImage.dimensions(data) != nil
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var settings = try loadCoverSettings(for: identity)
        let oldURL = customCoverURL(for: settings)
        settings.customFileName = UUID().uuidString
        settings.useCustomCover = true
        let url = directory.appendingPathComponent("Custom Covers", isDirectory: true)
            .appendingPathComponent(settings.customFileName ?? "")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        do {
            try saveCoverSettings(settings, for: identity)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        if let oldURL { try? FileManager.default.removeItem(at: oldURL) }
        return settings
    }

    public nonisolated func customCoverURL(for settings: GameCoverSettings) -> URL? {
        guard let name = settings.customFileName, UUID(uuidString: name) != nil else { return nil }
        let url = directory.appendingPathComponent("Custom Covers", isDirectory: true).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private nonisolated func coverSettingsLocation(for identity: String) -> URL {
        location(for: identity).appendingPathExtension("cover-settings")
    }

    public func load(for identity: String) throws -> GameMetadata? {
        try loadRecord(for: identity)?.resolved().metadata
    }

    public func loadRecord(for identity: String) throws -> GameMetadataRecord? {
        let url = location(for: identity)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try GameMetadataRecord.decode(data)
    }

    public func save(_ metadata: GameMetadata, for identity: String) throws {
        var record = try loadRecord(for: identity) ?? GameMetadataRecord(legacy: metadata)
        record.bindings[metadata.source.rawValue] = metadata.sourceID
        record.snapshots[metadata.source.rawValue] = metadata
        try saveRecord(record, for: identity)
    }

    public func saveRecord(_ record: GameMetadataRecord, for identity: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: location(for: identity), options: .atomic)
    }

    /// No actor suspension between validating the current binding and publishing.
    public func updateSnapshot(
        _ snapshot: GameMetadata,
        for identity: String,
        preservingCharacters: Bool = false
    ) throws -> Bool {
        guard var current = try loadRecord(for: identity),
              current.bindings[snapshot.source.rawValue] == snapshot.sourceID else { return false }
        var snapshot = snapshot
        if preservingCharacters,
           current.snapshots[snapshot.source.rawValue]?.sourceID == snapshot.sourceID {
            snapshot.characters = current.snapshots[snapshot.source.rawValue]?.characters
        }
        current.snapshots[snapshot.source.rawValue] = snapshot
        try saveRecord(current, for: identity)
        return true
    }

    public func remove(for identity: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: manualLocation(for: identity), options: .atomic)
        let url = location(for: identity)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func allowsAutomaticMatch(for identity: String) throws -> Bool {
        try loadRecord(for: identity) == nil
            && !FileManager.default.fileExists(atPath: manualLocation(for: identity).path)
    }

    /// Exclusive creation also protects a manual save through another store actor.
    public func saveAutomatic(_ metadata: GameMetadata, for identity: String) throws {
        try saveAutomaticRecord(GameMetadataRecord(legacy: metadata), for: identity)
    }

    public func saveAutomaticRecord(_ record: GameMetadataRecord, for identity: String) throws {
        guard try allowsAutomaticMatch(for: identity) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record)
            .write(to: location(for: identity), options: .withoutOverwriting)
    }

    /// Artwork is keyed by its URL, not by title, so two works cannot overwrite
    /// each other's cover. Keep the remote URL in metadata for provenance.
    public nonisolated func cachedCoverURL(for url: URL) -> URL? {
        let location = coverLocation(for: url)
        return FileManager.default.fileExists(atPath: location.path) ? location : nil
    }

    public func cacheCover(from url: URL, session: URLSession = .shared) async throws {
        guard cachedCoverURL(for: url) == nil else { return }
        try await networkAccess()
        guard url.scheme == "https" else { throw URLError(.unsupportedURL) }
        if let until = artworkFailures[url] {
            guard until <= Date() else { throw URLError(.resourceUnavailable) }
            artworkFailures[url] = nil
        }
        if let download = artworkDownloads[url] {
            try await download.value
            try Task.checkCancellation()
            return
        }

        let limiter: ArtworkTransportLimiter
        if session === URLSession.shared {
            limiter = .shared
        } else {
            let identifier = ObjectIdentifier(session)
            if let existing = artworkLimiters[identifier] {
                limiter = existing
            } else {
                let created = ArtworkTransportLimiter(minInterval: 0)
                artworkLimiters[identifier] = created
                limiter = created
            }
        }
        let location = coverLocation(for: url)
        let download = Task {
            let request = {
                var request = URLRequest(url: url, timeoutInterval: 20)
                request.setValue("Whisky/1.0 (game metadata)", forHTTPHeaderField: "User-Agent")
                return request
            }()
            let data = try await limiter.download(host: url.host ?? "") {
                try await ArtworkDataLoader.download(request, configuration: session.configuration)
            }
            try Task.checkCancellation()
            try FileManager.default.createDirectory(
                at: location.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: location, options: .atomic)
        }
        artworkDownloads[url] = download
        do {
            try await download.value
            artworkDownloads[url] = nil
            artworkFailures[url] = nil
        } catch {
            artworkDownloads[url] = nil
            if !Task.isCancelled {
                let retryAfter = (error as? ArtworkRateLimitError)?.retryAfter ?? 30
                artworkFailures[url] = Date().addingTimeInterval(max(30, retryAfter))
            }
            throw error
        }
        try Task.checkCancellation()
    }

    /// Copies saved metadata, manual-unlink markers, and cached cover artwork to another bottle's store.
    public func copyEntry(
        for sourceIdentity: String,
        to targetStore: GameMetadataStore,
        targetIdentity: String
    ) async throws {
        let fileManager = FileManager.default
        let sourceManual = manualLocation(for: sourceIdentity)
        let targetManual = targetStore.manualLocation(for: targetIdentity)
        if fileManager.fileExists(atPath: sourceManual.path), !fileManager.fileExists(atPath: targetManual.path) {
            try fileManager.createDirectory(
                at: targetManual.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? fileManager.copyItem(at: sourceManual, to: targetManual)
        }

        if fileManager.fileExists(atPath: coverSettingsLocation(for: sourceIdentity).path),
           !fileManager.fileExists(atPath: targetStore.coverSettingsLocation(for: targetIdentity).path) {
            let settings = try loadCoverSettings(for: sourceIdentity)
            if let sourceCover = customCoverURL(for: settings), let name = settings.customFileName {
                let targetCover = targetStore.directory.appendingPathComponent("Custom Covers", isDirectory: true)
                    .appendingPathComponent(name)
                try fileManager.createDirectory(
                    at: targetCover.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if !fileManager.fileExists(atPath: targetCover.path) {
                    try fileManager.copyItem(at: sourceCover, to: targetCover)
                }
            }
            try await targetStore.saveCoverSettings(settings, for: targetIdentity)
        }

        if let record = try loadRecord(for: sourceIdentity) {
            if try await targetStore.loadRecord(for: targetIdentity) == nil {
                try await targetStore.saveRecord(record, for: targetIdentity)
            }
            for metadata in record.snapshots.values {
                if let coverURL = metadata.coverURL,
                   let sourceCover = cachedCoverURL(for: coverURL),
                   targetStore.cachedCoverURL(for: coverURL) == nil {
                    let targetCover = targetStore.coverLocation(for: coverURL)
                    try fileManager.createDirectory(
                        at: targetCover.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    try? fileManager.copyItem(at: sourceCover, to: targetCover)
                }
            }
        }
    }

    public nonisolated func manualLocation(for identity: String) -> URL {
        location(for: identity).appendingPathExtension("manual")
    }

    public nonisolated func coverLocation(for url: URL) -> URL {
        LibraryStorageLayout.cachedCover(url, directory: directory)
    }

    private nonisolated func location(for identity: String) -> URL {
        let digest = LibraryStorageLayout.key(identity)
        return directory.appendingPathComponent(digest).appendingPathExtension("json")
    }
}

private struct ArtworkRateLimitError: Error, Sendable {
    let statusCode: Int
    let retryAfter: TimeInterval
}

private actor ArtworkTransportLimiter {
    static let shared = ArtworkTransportLimiter(minInterval: 0.25)

    private let minInterval: TimeInterval
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var nextRequestAt: [String: Date] = [:]

    init(minInterval: TimeInterval) {
        self.minInterval = minInterval
    }

    func download(
        host: String,
        operation: @Sendable () async throws -> Data
    ) async throws -> Data {
        try await acquire()
        defer { release() }
        let now = Date()
        let start = max(now, nextRequestAt[host] ?? now)
        nextRequestAt[host] = start.addingTimeInterval(minInterval)
        let delay = start.timeIntervalSince(now)
        if delay > 0 {
            try await Task.sleep(for: .seconds(delay))
        }
        return try await operation()
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

private final class ArtworkDataLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let maximumBytes = 15 * 1_024 * 1_024

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
        let state: (CheckedContinuation<Data, any Error>, URLSession, URLSessionDataTask)? = lock.withLock {
            guard let continuation, let session, let task else { return nil }
            self.continuation = nil
            self.session = nil
            self.task = nil
            return (continuation, session, task)
        }
        guard let (continuation, session, task) = state else { return }
        task.cancel()
        session.invalidateAndCancel()
        continuation.resume(with: result)
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

/// Presentation choices stay independent of provider snapshots and cache refreshes.
public struct GameCoverSettings: Codable, Equatable, Sendable {
    public var useCustomCover = false
    public var customFileName: String?
    public var zoom: Double = 1
    public var horizontalPosition: Double = 0.5
    public var verticalPosition: Double = 0.5

    public init() {}
}
