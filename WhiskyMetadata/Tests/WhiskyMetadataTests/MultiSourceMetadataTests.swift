import Foundation
import Testing
import WhiskyCore
@testable import WhiskyMetadata
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Test func confirmedIDRefreshLoadsRealCharacters() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CharacterFixtureProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    for (source, id) in [(GameMetadataSource.bangumi, "1"), (.vndb, "v1")] {
        let game = try await PublicGameMetadataProvider(source: source, session: session, networkAccess: {})
            .refresh(sourceID: id)
        #expect(game.sourceID == id)
        #expect(game.characters?.count == 1)
        #expect(game.characters?.first?.name == "Character")
        #expect(game.characters?.first?.role == "main")
    }
}

private final class CharacterFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let body: String
        switch url.path {
        case "/v0/subjects/1":
            body = #"{"id":1,"name":"Game","summary":"Summary"}"#
        case "/v0/subjects/1/characters":
            body = #"[{"id":2,"name":"Character","relation":"main"}]"#
        case "/kana/vn":
            body = #"{"results":[{"id":"v1","title":"Game"}]}"#
        case "/kana/character":
            body = #"{"more":false,"results":[{"id":"c2","name":"Character","vns":[{"id":"v1","role":"main"}]}]}"#
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func metadataResolutionRequiresConfirmedBindingsAndPreservesProvenance() throws {
    let basic = GameMetadata(source: .bangumi, sourceID: "1", title: "Basic", summary: "Original")
    let other = GameMetadata(source: .vndb, sourceID: "v2", title: "Other", summary: "Summary")
    var record = GameMetadataRecord(legacy: basic)
    record.snapshots["vndb"] = other
    record.categorySources["summary"] = .vndb
    #expect(record.resolved().metadata?.summary == "")
    #expect(record.resolved().provenance["summary"] == nil)
    record.bindings["vndb"] = "v2"
    #expect(record.resolved().metadata?.title == "Basic")
    #expect(record.resolved().metadata?.summary == "Summary")
    #expect(record.resolved().provenance["summary"]?.source == .vndb)
    record.manualTitle = "Manual"
    record.manualSummary = ""
    #expect(record.resolved().metadata?.title == "Manual")
    #expect(record.resolved().metadata?.summary == "")
    #expect(record.resolved().provenance["title"]?.manual == true)
    #expect(record.snapshots["bangumi"]?.title == "Basic")
    record.bindings["vndb"] = "v3"
    record.manualSummary = nil
    #expect(record.resolved().metadata?.summary == "")
}

@Test func legacyLocalVNDBTitleSurvivesProviderRefresh() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let remote = GameMetadata(source: .vndb, sourceID: "v17", title: "Ever17",
                              originalTitle: "Ever17", titleLanguage: "ja")
    let legacy = remote.usingLibraryTitle("时空轮回")
    #expect(legacy.title == "时空轮回")
    let path = root.appendingPathComponent(LibraryStorageLayout.key("game")).appendingPathExtension("json")
    try JSONEncoder().encode(legacy).write(to: path)
    let store = GameMetadataStore(directory: root, networkAccess: {})
    let migrated = try #require(await store.loadRecord(for: "game"))
    #expect(migrated.manualTitle == "时空轮回")
    #expect(try await store.updateSnapshot(remote, for: "game"))
    #expect(try await store.load(for: "game")?.title == "时空轮回")
    #expect(try await store.load(for: "game")?.provenance?["title"]?.manual == true)
    #expect(try await store.loadRecord(for: "game")?.snapshots["vndb"]?.title == "Ever17")
    #expect(GameMetadataRecord(legacy: remote).manualTitle == nil)
    let officialChinese = GameMetadata(source: .vndb, sourceID: "v1", title: "中文",
                                       alternateTitles: ["Original"], titleLanguage: "zh-Hans")
    #expect(GameMetadataRecord(legacy: officialChinese).manualTitle == nil)
}

@Test func metadataLegacyMigrationCopyAndCustomCoverSettings() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    let target = root.appendingPathComponent("target")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let legacy = GameMetadata(source: .vndb, sourceID: "v1", title: "Legacy")
    let path = source.appendingPathComponent(LibraryStorageLayout.key("game")).appendingPathExtension("json")
    let bytes = try JSONEncoder().encode(legacy)
    try bytes.write(to: path)
    let store = GameMetadataStore(directory: source, networkAccess: {})
    var record = try #require(await store.loadRecord(for: "game"))
    #expect(record.defaultSource == .vndb)
    #expect(try Data(contentsOf: path) == bytes)
    record.manualTitle = "Custom"
    record.categorySources["cover"] = .bangumi
    try await store.saveRecord(record, for: "game")
    let additional = GameMetadata(source: .bangumi, sourceID: "2", title: "Additional")
    try await store.save(additional, for: "game")
    let afterLegacySave = try #require(await store.loadRecord(for: "game"))
    #expect(afterLegacySave.defaultSource == .vndb)
    #expect(afterLegacySave.categorySources == record.categorySources)
    #expect(afterLegacySave.manualTitle == "Custom")
    #expect(afterLegacySave.bindings["bangumi"] == "2")
    #expect(afterLegacySave.snapshots["vndb"] == legacy)
    var settings = GameCoverSettings()
    settings.zoom = 1.5
    try await store.saveCoverSettings(settings, for: "game")
    let destination = GameMetadataStore(directory: target, networkAccess: {})
    try await store.copyEntry(for: "game", to: destination, targetIdentity: "copy")
    #expect(try await destination.loadRecord(for: "copy")?.categorySources["cover"] == .bangumi)
    #expect(try await destination.load(for: "copy")?.title == "Custom")
    #expect(try await destination.loadCoverSettings(for: "copy").zoom == 1.5)
    var changed = record
    changed.bindings["vndb"] = "v2"
    try await destination.saveRecord(changed, for: "copy")
    #expect(try await destination.updateSnapshot(legacy, for: "copy") == false)
    #expect(try await destination.loadRecord(for: "copy")?.bindings["vndb"] == "v2")
    #expect(try await destination.loadRecord(for: "copy")?.manualTitle == "Custom")
    try await store.saveRecord(GameMetadataRecord(), for: "empty")
    #expect(try await store.allowsAutomaticMatch(for: "empty") == false)
}
