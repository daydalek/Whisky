//
//  PortableMetadataJobTests.swift
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

private final class SlowCharacterCompletion: @unchecked Sendable {
    private weak var protocolHandler: URLProtocol?
    private let url: URL?

    init(_ protocolHandler: URLProtocol) {
        self.protocolHandler = protocolHandler
        url = protocolHandler.request.url
    }

    func finish() {
        guard let protocolHandler,
              let url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else { return }
        protocolHandler.client?.urlProtocol(protocolHandler, didReceive: response, cacheStoragePolicy: .notAllowed)
        protocolHandler.client?.urlProtocol(protocolHandler, didLoad: Data("[]".utf8))
        protocolHandler.client?.urlProtocolDidFinishLoading(protocolHandler)
    }
}

private final class SlowCharacterProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let completion = SlowCharacterCompletion(self)
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
            completion.finish()
        }
    }

    override func stopLoading() {}
}

@Test @MainActor func metadataApplyJobSurvivesSlowCharacterFetch() async throws {
    let fixture = try MetadataFixture()
    defer { fixture.remove() }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SlowCharacterProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let jobs = BridgeJobStore()
    let service = LibraryMetadataService(jobs: jobs, session: session, networkAccess: {})
    let entry = try await fixture.workspace.entry(fixture.params)
    let store = GameMetadataStore(directory: entry.metadataDirectory, networkAccess: {})
    let metadata = GameMetadata(source: .bangumi, sourceID: "42", title: "Test")
    try await store.save(metadata, for: entry.metadataIdentity)
    var snapshot = try #require(try JSONValue.encoded(metadata).object)
    snapshot["refreshCharacters"] = .bool(true)
    var params = fixture.params
    params["metadata"] = .object(snapshot)
    params["background"] = .bool(true)
    let started = try await service.call("metadata.apply", params: params, workspace: fixture.workspace)
    let id = try #require(started.object?["jobID"]?.string)
    try await Task.sleep(for: .milliseconds(5_200))
    let pending = try jobs.call("jobs.get", params: ["jobID": .string(id)])
    #expect(pending.object?["status"] == .string("running"))
    _ = try await waitForMetadataJob(started, jobs: jobs)
    #expect(try await store.load(for: entry.metadataIdentity)?.characters == [])
}

@Test @MainActor func metadataApplyJobReportsStaleGameFailure() async throws {
    let fixture = try MetadataFixture()
    defer { fixture.remove() }
    let jobs = BridgeJobStore()
    let service = LibraryMetadataService(jobs: jobs, networkAccess: {})
    let metadata = GameMetadata(source: .bangumi, sourceID: "42", title: "Test")
    var snapshot = try #require(try JSONValue.encoded(metadata).object)
    snapshot["refreshCharacters"] = .bool(true)
    var params = fixture.params
    params["metadata"] = .object(snapshot)
    params["background"] = .bool(true)
    let started = try await service.call("metadata.apply", params: params, workspace: fixture.workspace)
    let id = try #require(started.object?["jobID"]?.string)
    for _ in 0 ..< 100 {
        let job = try jobs.call("jobs.get", params: ["jobID": .string(id)])
        if job.object?["status"] == .string("failed") {
            #expect(job.object?["error"]?.object?["code"] == .string("operation_failed"))
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("Stale metadata job did not fail")
}

@Test @MainActor func portableMetadataSearchCachesThumbnailsAndSyncRetainsConcurrentFolderEdits() async throws {
    let fixture = try MetadataFixture()
    defer { fixture.remove() }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MetadataJobProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel()
        MetadataJobProtocol.setHook(nil)
    }
    let jobs = BridgeJobStore()
    let preferences = PreferencesService(
        fileURL: fixture.root.appendingPathComponent("preferences.plist"),
        defaultBottleDirectory: fixture.root
    )
    _ = try preferences.call("preferences.setMany", params: ["values": .object([
        "libraryMetadataSummarySource": .string("vndb"),
        "libraryMetadataCharactersSource": .string("vndb")
    ])])
    let service = LibraryMetadataService(jobs: jobs, session: session, preferences: preferences, networkAccess: {})
    var params = fixture.params
    params["query"] = .string("Test")
    params["sources"] = .array([.string("bangumi")])
    let started = try await service.call("metadata.search", params: params, workspace: fixture.workspace)
    let result = try await waitForMetadataJob(started, jobs: jobs)
    let groups = try #require(result.object?["results"]).decoded([JSONValue].self)
    let games = try #require(groups.first?.object?["games"]).decoded([JSONValue].self)
    let thumbnail = try #require(games.first?.object?["thumbnail"]?.string)
    #expect(try Data(contentsOf: URL(fileURLWithPath: thumbnail)) == pngPixel)

    let folder = fixture.bottle.appendingPathComponent("Games/Test")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var library = FolderGameLibrary()
    library.roots = ["Games"]
    library.initializedRoots = ["Games"]
    library.knownFolders = ["Games/Test"]
    library.pendingMetadata = ["Games/Test"]
    try library.save(bottleURL: fixture.bottle)
    let location = fixture.bottle.appendingPathComponent("Folder Games.json")
    MetadataJobProtocol.setHook {
        let lock = location.appendingPathExtension("lock")
        try HostFileLock().withExclusiveLock(at: lock) {
            var current = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: location)) as? [String: Any])
            current["roots"] = ["Games", "Other"]
            current["executables"] = ["Games/Test": "drive_c/Games/Test/game.exe"]
            current["pendingMetadata"] = ["Games/Test", "Other/New"]
            current["future"] = "retained"
            try JSONSerialization.data(withJSONObject: current).write(to: location, options: .atomic)
        }
    }
    params["automatic"] = .bool(true)
    let sync = try await service.call("metadata.sync", params: params, workspace: fixture.workspace)
    let synced = try await waitForMetadataJob(sync, jobs: jobs)
    #expect(synced.object?["matched"] == .integer(1))
    let folderEntry = try #require(try await fixture.workspace.entries(in: fixture.bottle)
        .first { $0.source == .folder })
    let store = GameMetadataStore(directory: folderEntry.metadataDirectory, networkAccess: {})
    let record = try #require(await store.loadRecord(for: folderEntry.metadataIdentity))
    #expect(record.categorySources["summary"] == .vndb)
    #expect(record.categorySources["characters"] == .vndb)
    #expect(record.bindings == ["bangumi": "42"])
    #expect(record.resolved().metadata?.summary == "")
    #expect(record.resolved().metadata?.characters == nil)
    let current = try FolderGameLibrary.load(bottleURL: fixture.bottle)
    #expect(current.roots == ["Games", "Other"])
    #expect(current.executables["Games/Test"] == "drive_c/Games/Test/game.exe")
    #expect(current.pendingMetadata == ["Other/New"])
    let raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: location)) as? [String: Any])
    #expect(raw["future"] as? String == "retained")
}
