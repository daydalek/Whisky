//
//  PortableMetadataTests.swift
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

private struct MetadataFixture {
    let root: URL
    let bottle: URL
    let executable: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisky-metadata-\(UUID())")
        bottle = root.appendingPathComponent("Bottle")
        executable = bottle.appendingPathComponent("drive_c/Games/Test/game.exe")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x4D, 0x5A]).write(to: executable)
        struct Pin: Encodable {
            let name: String
            let url: URL
            let removable: Bool
        }
        struct Info: Encodable {
            let name: String
            let pins: [Pin]
            let blocklist: [URL]
        }
        struct Metadata: Encodable {
            let info: Info
        }
        let metadata = Metadata(info: Info(
            name: "Metadata Test",
            pins: [Pin(name: "Test", url: executable, removable: false)],
            blocklist: []
        ))
        try PropertyListEncoder().encode(metadata)
            .write(to: bottle.appendingPathComponent("Metadata.plist"))
    }

    var workspace: ApplicationWorkspace {
        ApplicationWorkspace(containers: [bottle])
    }

    var entryID: String {
        "pinned:\(executable.path)"
    }

    var params: [String: JSONValue] {
        [
            "container": .string(bottle.path),
            "entryID": .string(entryID)
        ]
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor private func metadataService() -> LibraryMetadataService {
    LibraryMetadataService(jobs: BridgeJobStore(), networkAccess: {})
}

/// A complete 4 × 2 PNG with an opaque orange fill.
private let pngPixel = Data(base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAYAAAB/qH1jAAAAEklEQVR4nGP43+HyHxkzoAsAAHyRFlERVA2OAAAAAElFTkSuQmCC"
) ?? Data()

@MainActor private func waitForMetadataJob(_ started: JSONValue, jobs: BridgeJobStore) async throws -> JSONValue {
    let id = try #require(started.object?["jobID"]?.string)
    for _ in 0 ..< 150 {
        let job = try jobs.call("jobs.get", params: ["jobID": .string(id)])
        if job.object?["status"] == .string("completed") {
            return try #require(job.object?["result"])
        }
        if job
            .object?["status"] == .string("failed") {
            throw BridgeFailure("test_job_failed", String(describing: job))
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw BridgeFailure("test_timeout", "Metadata fixture job timed out")
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
    let service = LibraryMetadataService(jobs: jobs, session: session, networkAccess: {})
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
    let current = try FolderGameLibrary.load(bottleURL: fixture.bottle)
    #expect(current.roots == ["Games", "Other"])
    #expect(current.executables["Games/Test"] == "drive_c/Games/Test/game.exe")
    #expect(current.pendingMetadata == ["Other/New"])
    let raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: location)) as? [String: Any])
    #expect(raw["future"] as? String == "retained")
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

private final class MetadataJobProtocol: URLProtocol, @unchecked Sendable {
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
            let data = isImage ? pngPixel :
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

@Test @MainActor func portableMetadataApplyImportCoverAndClear() async throws {
    let fixture = try MetadataFixture()
    defer { fixture.remove() }
    let service = metadataService()
    let entry = try await fixture.workspace.entry(fixture.params)
    let store = GameMetadataStore(directory: entry.metadataDirectory, networkAccess: {})
    let metadata = GameMetadata(
        source: .bangumi,
        sourceID: "42",
        title: "测试游戏",
        originalTitle: "Test Game",
        summary: "Summary",
        developer: "Studio",
        releaseDate: "2020-01-01"
    )

    var params = fixture.params
    params["metadata"] = try .encoded(metadata)
    _ = try await service.call(
        "metadata.apply",
        params: params,
        workspace: fixture.workspace
    )
    let saved = try #require(try await store.load(for: entry.metadataIdentity))
    #expect(saved.title == "测试游戏")
    #expect(saved.source == .bangumi)

    let cover = fixture.root.appendingPathComponent("cover.png")
    try pngPixel.write(to: cover)
    var coverParams = fixture.params
    coverParams["path"] = .string(cover.path)
    _ = try await service.call(
        "metadata.cover.import",
        params: coverParams,
        workspace: fixture.workspace
    )
    let settings = try await store.loadCoverSettings(for: entry.metadataIdentity)
    #expect(settings.useCustomCover)
    #expect(store.customCoverURL(for: settings) != nil)

    _ = try await service.call(
        "metadata.cover.reset",
        params: fixture.params,
        workspace: fixture.workspace
    )
    #expect(try await !store.loadCoverSettings(for: entry.metadataIdentity).useCustomCover)

    _ = try await service.call(
        "metadata.clear",
        params: fixture.params,
        workspace: fixture.workspace
    )
    #expect(try await store.load(for: entry.metadataIdentity) == nil)
}
