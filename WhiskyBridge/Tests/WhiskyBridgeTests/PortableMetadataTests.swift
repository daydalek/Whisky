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

@Test @MainActor func metadataHydrationStagesDetailsAndPreservesCompleteSnapshots() async throws {
    let fixture = try MetadataFixture()
    defer { fixture.remove() }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MetadataHydrationProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let jobs = BridgeJobStore()
    let service = LibraryMetadataService(jobs: jobs, session: session, networkAccess: {})
    var draft = GameMetadataRecord(defaultSource: .steam)
    draft.bindings["steam"] = "7"
    draft.snapshots["steam"] = GameMetadata(source: .steam, sourceID: "7", title: "Search hit")
    var params = fixture.params
    params["hydrate"] = .bool(true)
    params["background"] = .bool(true)
    params["sources"] = .array([.string("steam")])
    params["record"] = try .encoded(draft)
    let started = try await service.call("metadata.configuration.save", params: params, workspace: fixture.workspace)
    #expect(started.object?["jobID"]?.string != nil)
    let saved = try await waitForMetadataJob(started, jobs: jobs)
    params["background"] = .bool(false)
    let complete = try #require(saved.object?["record"]).decoded(GameMetadataRecord.self)
    #expect(complete.snapshots["steam"]?.summary == "Full summary")
    #expect(complete.snapshots["steam"]?.developer == "Developer")

    // A repeat search hit must neither fetch again nor replace full details.
    let offline = LibraryMetadataService(jobs: BridgeJobStore(), session: session,
                                         networkAccess: { throw URLError(.notConnectedToInternet) })
    draft.manualTitle = "Local"
    params["record"] = try .encoded(draft)
    let repeated = try await offline.call("metadata.configuration.save", params: params, workspace: fixture.workspace)
    let retained = try #require(repeated.object?["record"]).decoded(GameMetadataRecord.self)
    #expect(retained.snapshots["steam"]?.summary == "Full summary")
    #expect(retained.manualTitle == "Local")

    draft.bindings["steam"] = "8"
    draft.snapshots["steam"] = GameMetadata(source: .steam, sourceID: "8", title: "New search hit")
    draft.manualTitle = "Uncommitted"
    params["record"] = try .encoded(draft)
    do {
        _ = try await offline.call("metadata.configuration.save", params: params, workspace: fixture.workspace)
        Issue.record("Hydration failure committed the draft")
    } catch {}
    let afterFailure = try await offline.call("metadata.configuration.get", params: fixture.params,
                                              workspace: fixture.workspace)
    let unchanged = try #require(afterFailure.object?["record"]).decoded(GameMetadataRecord.self)
    #expect(unchanged.bindings["steam"] == "7")
    #expect(unchanged.snapshots["steam"]?.summary == "Full summary")
    #expect(unchanged.manualTitle == "Local")

    // Disabled sources still permit a local pending binding with no transport.
    params["sources"] = .array([])
    let pending = try await offline.call("metadata.configuration.save", params: params, workspace: fixture.workspace)
    let pendingRecord = try #require(pending.object?["record"]).decoded(GameMetadataRecord.self)
    #expect(pendingRecord.bindings["steam"] == "8")
    var refreshParams = fixture.params
    refreshParams["background"] = .bool(true)
    refreshParams["sources"] = .array([])
    let refreshJob = try await service.call("metadata.refresh", params: refreshParams, workspace: fixture.workspace)
    let refreshed = try await waitForMetadataJob(refreshJob, jobs: jobs)
    #expect(refreshed.object?["record"]?.object?["bindings"]?.object?["steam"] == .string("8"))
}

private final class MetadataHydrationProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              url.host == "store.steampowered.com", url.path == "/api/appdetails",
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = #"{"7":{"success":true,"data":{"name":"Complete","short_description":"Full summary","developers":["Developer"]}}}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test @MainActor func applicationDispatchesPreferenceBatchAndRejectsNoncanonicalBindings() async throws {
    let fixture = try MetadataFixture()
    defer { fixture.remove() }
    let preferences = PreferencesService(fileURL: fixture.root.appendingPathComponent("preferences.plist"),
                                         defaultBottleDirectory: fixture.root)
    let application = ApplicationService(workspace: fixture.workspace, preferences: preferences)
    let values = try await application.call("preferences.setMany", params: ["values": .object([
        "libraryMetadataDefaultSource": .string("vndb"),
        "libraryOnboardingCompleted": .bool(true)
    ])])
    #expect(values.object?["libraryMetadataDefaultSource"] == .string("vndb"))
    #expect(values.object?["libraryOnboardingCompleted"] == .bool(true))
    let reread = try await application.call("preferences.read", params: [:])
    #expect(reread.object?["libraryMetadataDefaultSource"] == .string("vndb"))
    for (source, id) in [("bangumi", "0001"), ("vndb", "v0001"), ("steam", "0"), ("ymgal", "01")] {
        var record = GameMetadataRecord()
        record.bindings[source] = id
        var params = fixture.params
        params["record"] = try .encoded(record)
        do {
            _ = try await application.call("metadata.configuration.save", params: params)
            Issue.record("Noncanonical binding accepted: \(source):\(id)")
        } catch let error as BridgeFailure {
            #expect(error.code == "invalid_params")
        }
    }
    let absent = try await application.call("metadata.configuration.get", params: fixture.params)
    #expect(absent.object?["hasRecord"] == .bool(false))
}

@Test @MainActor func metadataConfigurationDraftRefreshFailureAndPresentation() async throws {
    let fixture = try MetadataFixture()
    defer { fixture.remove() }
    let preferences = PreferencesService(fileURL: fixture.root.appendingPathComponent("prefs"),
                                         defaultBottleDirectory: fixture.root)
    _ = try preferences.call("preferences.setMany", params: ["values": .object([
        "libraryMetadataDefaultSource": .string("vndb"),
        "libraryMetadataCoverSource": .string("steam"),
        "libraryMetadataEnabledSources": .string(""),
        "libraryOnboardingCompleted": .bool(true)
    ])])
    let jobs = BridgeJobStore()
    let service = LibraryMetadataService(jobs: jobs, preferences: preferences,
                                        networkAccess: { throw URLError(.notConnectedToInternet) })
    let empty = try await service.call("metadata.configuration.get", params: fixture.params,
                                       workspace: fixture.workspace)
    #expect(empty.object?["hasRecord"] == .bool(false))
    var record = try #require(empty.object?["record"]).decoded(GameMetadataRecord.self)
    #expect(record.defaultSource == .vndb)
    #expect(record.categorySources["cover"] == .steam)
    record.bindings["vndb"] = "v1"
    record.snapshots["vndb"] = GameMetadata(source: .vndb, sourceID: "v1", title: "Saved")
    record.manualTitle = "Manual"
    var params = fixture.params
    params["record"] = try .encoded(record)
    _ = try await service.call("metadata.configuration.save", params: params, workspace: fixture.workspace)
    let entry = try await fixture.workspace.entry(fixture.params)
    #expect(try LibraryPresentation.load(for: entry).metadata?.title == "Manual")
    let refreshed = try await service.call("metadata.refresh", params: fixture.params, workspace: fixture.workspace)
    #expect(refreshed.object?["errors"]?.object?["vndb"]?.string != nil)
    let retained = try #require(refreshed.object?["record"]).decoded(GameMetadataRecord.self)
    #expect(retained.snapshots["vndb"]?.title == "Saved")
    #expect(retained.manualTitle == "Manual")
    do {
        _ = try preferences.call("preferences.setMany", params: ["values": .object([
            "libraryOnboardingCompleted": .bool(false), "libraryMetadataDefaultSource": .string("bogus")
        ])])
        Issue.record("Invalid source accepted")
    } catch {}
    let values = try preferences.call("preferences.read", params: [:])
    #expect(values.object?["libraryOnboardingCompleted"] == .bool(true))
    #expect(values.object?["libraryMetadataEnabledSources"] == .string(""))
    var searchParams = fixture.params
    searchParams["query"] = .string("Must not search")
    let search = try await service.call("metadata.search", params: searchParams, workspace: fixture.workspace)
    let result = try await waitForMetadataJob(search, jobs: jobs)
    #expect(result.object?["results"] == .array([]))
    searchParams["sources"] = .array([])
    let explicit = try await service.call("metadata.search", params: searchParams, workspace: fixture.workspace)
    #expect(try await waitForMetadataJob(explicit, jobs: jobs).object?["results"] == .array([]))
}

/// A complete 4 × 2 PNG with an opaque orange fill.
private let pngPixel = Data(base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAYAAAB/qH1jAAAAEklEQVR4nGP43+HyHxkzoAsAAHyRFlERVA2OAAAAAElFTkSuQmCC"
) ?? Data()

private final class SlowCharacterProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) { [self] in
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("[]".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
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
    let preferences = PreferencesService(fileURL: fixture.root.appendingPathComponent("preferences.plist"),
                                         defaultBottleDirectory: fixture.root)
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
    var snapshot = try #require(try JSONValue.encoded(metadata).object)
    snapshot["includeCharacters"] = .bool(false)
    params["metadata"] = .object(snapshot)
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

private let nextMoeGuideFixture = """
{"id":"1","work_id":"4","source":"example","source_url":"https://fixture.example/guide",
 "source_author":"Author","lang":"ja","release":null,"characters":[],"ending_count":1,
 "save_count":1,"segment_count":1,"work_route_hints":true,"work_content_limit":"sfw",
 "updated_at":"2026-01-01T00:00:00Z"}
"""

private final class WalkthroughFixtureProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        do {
            let url = try #require(request.url)
            #expect(url.path == "/v2/catalog/walkthroughs/1")
            var value = try #require(JSONSerialization.jsonObject(with: Data(nextMoeGuideFixture.utf8)) as? [String: Any])
            value["chart"] = ["sections": [], "entries": [], "saves": [], "endings": [], "segments": []]
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: value))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

@Test @MainActor func walkthroughJobMergesIntoLiveMetadataAndValidatesMembership() async throws {
    let fixture = try MetadataFixture()
    defer { fixture.remove() }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [WalkthroughFixtureProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let jobs = BridgeJobStore()
    let service = LibraryMetadataService(jobs: jobs, session: session, networkAccess: {})
    let entry = try await fixture.workspace.entry(fixture.params)
    let store = GameMetadataStore(directory: entry.metadataDirectory, networkAccess: {})
    let guide = try JSONDecoder().decode(GameWalkthrough.self, from: Data(nextMoeGuideFixture.utf8))
    let metadata = GameMetadata(source: .nextmoe, sourceID: "4", title: "Live title", walkthroughs: [guide])
    try await store.save(metadata, for: entry.metadataIdentity)
    var snapshot = try #require(try JSONValue.encoded(metadata).object)
    snapshot["title"] = .string("Stale title")
    snapshot["walkthroughID"] = .string("1")
    var params = fixture.params
    params["metadata"] = .object(snapshot)
    params["background"] = .bool(true)
    let started = try await service.call("metadata.apply", params: params, workspace: fixture.workspace)
    _ = try await waitForMetadataJob(started, jobs: jobs)
    let saved = try #require(try await store.load(for: entry.metadataIdentity))
    #expect(saved.title == "Live title")
    #expect(saved.walkthroughs?.first?.chart != nil)
    #expect(saved.walkthroughs?.first?.sourceAuthor == "Author")

    params["background"] = .bool(false)
    snapshot["walkthroughID"] = .string("2")
    params["metadata"] = .object(snapshot)
    await #expect(throws: BridgeFailure.self) {
        try await service.call("metadata.apply", params: params, workspace: fixture.workspace)
    }
    try await store.remove(for: entry.metadataIdentity)
    snapshot["walkthroughID"] = .string("1")
    params["metadata"] = .object(snapshot)
    await #expect(throws: BridgeFailure.self) {
        try await service.call("metadata.apply", params: params, workspace: fixture.workspace)
    }
    #expect(try await store.load(for: entry.metadataIdentity) == nil)
}
