//
//  PortableMetadataRefreshTests.swift
//  WhiskyBridgeTests
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
import WhiskyApplication
import WhiskyBridgeProtocol
import WhiskyCore
import WhiskyMetadata
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Test @MainActor func automaticMetadataRetiresOnlyCompletedOrUnmatchedPendingEntries() async throws {
    for mode in ["failure", "success", "no-match"] {
        let fixture = try MetadataFixture()
        defer { fixture.remove() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataOutcomeProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        MetadataOutcomeProtocol.setMode(mode)
        let folder = fixture.bottle.appendingPathComponent("Games/Test")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var library = FolderGameLibrary()
        library.automaticMetadata = true
        library.roots = ["Games"]
        library.initializedRoots = ["Games"]
        library.knownFolders = ["Games/Test"]
        library.pendingMetadata = ["Games/Test"]
        try library.save(bottleURL: fixture.bottle)
        let jobs = BridgeJobStore()
        let service = LibraryMetadataService(jobs: jobs, session: session, networkAccess: {})
        var params = fixture.params
        params["automatic"] = .bool(true)
        params["includeCharacters"] = .bool(true)
        params["sources"] = .array([.string("bangumi")])
        let result = try await waitForMetadataJob(
            service.call("metadata.sync", params: params, workspace: fixture.workspace),
            jobs: jobs
        )
        let current = try FolderGameLibrary.load(bottleURL: fixture.bottle)
        if mode == "failure" {
            #expect(result.object?["failed"] == .integer(1))
            #expect(current.pendingMetadata == ["Games/Test"])
        } else {
            #expect(result.object?["failed"] == .integer(0))
            #expect(current.pendingMetadata.isEmpty)
        }
    }
}

@Test @MainActor func characterPreferenceControlsHydrationAndRefreshWithoutErasingCache() async throws {
    let fixture = try MetadataFixture()
    defer { fixture.remove() }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PreferenceRefreshProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let preferences = PreferencesService(
        fileURL: fixture.root.appendingPathComponent("preferences.plist"),
        defaultBottleDirectory: fixture.root
    )
    _ = try preferences.call("preferences.set", params: [
        "key": .string("libraryMetadataScrapeCharacters"),
        "value": .bool(false)
    ])
    let service = LibraryMetadataService(
        jobs: BridgeJobStore(),
        session: session,
        preferences: preferences,
        networkAccess: {}
    )
    let entry = try await fixture.workspace.entry(fixture.params)
    let store = GameMetadataStore(directory: entry.metadataDirectory, networkAccess: {})
    let candidate = GameMetadata(source: .bangumi, sourceID: "42", title: "Search result")
    var params = fixture.params
    params["record"] = try .encoded(GameMetadataRecord(legacy: candidate))
    params["hydrate"] = .bool(true)
    params["sources"] = .array([.string("bangumi")])
    PreferenceRefreshProtocol.reset()
    _ = try await service.call("metadata.configuration.save", params: params, workspace: fixture.workspace)
    #expect(PreferenceRefreshProtocol.paths == ["/v0/subjects/42"])

    var record = try #require(try await store.loadRecord(for: entry.metadataIdentity))
    record.snapshots["bangumi"]?.characters = [GameCharacter(id: "old", name: "Cached")]
    try await store.saveRecord(record, for: entry.metadataIdentity)
    PreferenceRefreshProtocol.reset()
    _ = try await service.call("metadata.refresh", params: fixture.params, workspace: fixture.workspace)
    let preserved = try #require(try await store.loadRecord(for: entry.metadataIdentity))
    #expect(preserved.snapshots["bangumi"]?.characters?.map(\.id) == ["old"])
    #expect(PreferenceRefreshProtocol.paths == ["/v0/subjects/42"])

    PreferenceRefreshProtocol.reset()
    var explicit = fixture.params
    explicit["includeCharacters"] = .bool(true)
    _ = try await service.call("metadata.refresh", params: explicit, workspace: fixture.workspace)
    let refreshed = try #require(try await store.loadRecord(for: entry.metadataIdentity))
    #expect(refreshed.snapshots["bangumi"]?.characters == [])
    #expect(PreferenceRefreshProtocol.paths == ["/v0/subjects/42", "/v0/subjects/42/characters"])
}

private final class MetadataOutcomeProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var mode = "success"

    static func setMode(_ value: String) { lock.withLock { mode = value } }
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        let mode = Self.lock.withLock { Self.mode }
        let isCharacters = url.path.hasSuffix("/characters")
        let status = mode == "failure" && isCharacters ? 500 : 200
        let data = if isCharacters {
            Data("[]".utf8)
        } else if mode == "no-match" {
            Data(#"{"data":[]}"#.utf8)
        } else {
            Data(#"{"data":[{"id":42,"name":"Test","name_cn":"Test"}]}"#.utf8)
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class PreferenceRefreshProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var requestedPaths: [String] = []

    static var paths: [String] { lock.withLock { requestedPaths } }
    static func reset() { lock.withLock { requestedPaths = [] } }
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.withLock { Self.requestedPaths.append(url.path) }
        let data = url.path.hasSuffix("/characters")
            ? Data("[]".utf8)
            : Data(#"{"id":42,"name":"Refreshed","name_cn":"Refreshed","summary":"Updated"}"#.utf8)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Test @MainActor func applicationMetadataUsesTheLiveOfflinePreference() async throws {
    let fixture = try MetadataFixture()
    defer { fixture.remove() }
    let preferences = PreferencesService(
        fileURL: fixture.root.appendingPathComponent("preferences.plist"),
        defaultBottleDirectory: fixture.root
    )
    _ = try preferences.call("preferences.set", params: ["key": .string("offlineMode"), "value": .bool(true)])
    let jobs = BridgeJobStore()
    let service = ApplicationService(workspace: fixture.workspace, preferences: preferences, jobs: jobs)
    let description = try await service.call("bridge.describe", params: [:])
    let capabilities = try #require(description.object?["capabilities"]).decoded([String].self)
    #expect(capabilities.contains("metadata.edit"))
    var params = fixture.params
    params["query"] = .string("Test")
    params["sources"] = .array([.string("bangumi")])
    let result = try await waitForMetadataJob(service.call("metadata.search", params: params), jobs: jobs)
    let groups = try #require(result.object?["results"]).decoded([JSONValue].self)
    #expect(groups.first?.object?["error"]?.string?.isEmpty == false)
    #expect(groups.first?.object?["games"] == .array([]))
}

final class MetadataJobProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var hook: (@Sendable () throws -> Void)?
    static func setHook(_ callback: (@Sendable () throws -> Void)?) {
        lock.withLock { hook = callback }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let isImage = request.url?.host == "fixture.example"
            if !isImage {
                try Self.lock.withLock { Self.hook }?()
            }
            let isCharacters = request.url?.path.hasSuffix("/characters") == true
            let data = isImage ? pngPixel : isCharacters ? Data("[]".utf8) :
                Data(
                    #"""
                    {"data":[{"id":42,"name":"Test","name_cn":"Test",
                    "images":{"large":"https://fixture.example/cover.png"}}]}
                    """#
                    .utf8
                )
            guard let url = request.url, let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": isImage ? "image/png" : "application/json"]
            )
            else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    override func stopLoading() {}
}
