// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import WhiskyKit

@Suite("Game Metadata")
struct GameMetadataTests {
    @Test func roundTripAndRemoval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GameMetadataStore(directory: directory)
        let game = GameMetadata(source: .vndb, sourceID: "v17", title: "作品", summary: "简介")
        #expect(try await store.load(for: "A") == nil)
        try await store.save(game, for: "A")
        #expect(try await store.load(for: "A") == game)
        #expect(try await store.load(for: "B") == nil)
        try await store.remove(for: "A")
        #expect(try await store.load(for: "A") == nil)
        try await store.remove(for: "A")
    }

    @Test func identitySurvivesBottleMoveAndSeparatesExecutables() {
        func item(root: String, path: String) -> LibraryEntry {
            let bottle = URL(fileURLWithPath: root)
            let executable = bottle.appendingPathComponent(path)
            return LibraryEntry(id: executable.path, name: "Launch", iconURL: executable,
                                bottleURL: bottle, source: .pinned, launch: .program(executable))
        }
        let first = item(root: "/old/bottle", path: "drive_c/A/Launch.exe")
        let moved = item(root: "/new/bottle", path: "drive_c/A/Launch.exe")
        let other = item(root: "/old/bottle", path: "drive_c/B/Launch.exe")
        #expect(first.metadataIdentity == moved.metadataIdentity)
        #expect(first.metadataIdentity != other.metadataIdentity)
    }

    @Test func failureDoesNotDiscardSuccessfulSource() async {
        let results = await GameMetadataSearch.search("test", providers: [
            FixtureProvider(source: .bangumi, fails: false),
            FixtureProvider(source: .vndb, fails: true)
        ])
        #expect(results.count == 2)
        #expect(results.first { $0.source == .bangumi }?.games.count == 1)
        #expect(results.first { $0.source == .vndb }?.error != nil)
    }

    @Test func emptyQueryDoesNotCallProviders() async {
        let result = await GameMetadataSearch.search(" \n", providers: [
            FixtureProvider(source: .bangumi, fails: false)
        ])
        #expect(result.isEmpty)
    }

    @Test func unconfiguredSourcesReportAnError() async {
        let results = await GameMetadataSearch.search("test", providers: [
            PublicGameMetadataProvider(source: .hikarinagi)
        ])
        #expect(results.count == 1)
        #expect(results.allSatisfy { $0.error != nil && $0.games.isEmpty })
    }

    @Test func decodesPublicSourceResponses() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for source in [GameMetadataSource.bangumi, .vndb, .steam, .ymgal] {
            let provider = PublicGameMetadataProvider(source: source, session: session)
            let games = try await provider.search("作品 & title")
            #expect(games.count == 1)
            #expect(games.first?.source == source)
            #expect(games.first?.coverURL?.scheme == "https")
        }
    }

    @Test func ymgalLoadsSelectedDetailsAndPreservesLargeID() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let provider = PublicGameMetadataProvider(source: .ymgal, session: session)
        let candidate = try #require(try await provider.search("作品 & title").first)
        #expect(candidate.sourceID == "9007199254740993")
        let detail = try await provider.details(for: candidate)
        #expect(detail.sourceID == candidate.sourceID)
        #expect(detail.summary == "完整简介")
        #expect(detail.developer == "Studio")
        #expect(detail.pageURL?.absoluteString == "https://www.ymgal.games/ga9007199254740993")
    }

    @Test func ymgalReportsBusinessErrorsAndBoundsAuthenticationRetry() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for query in ["rate-limit", "expired"] {
            let result = await GameMetadataSearch.search(query, providers: [
                PublicGameMetadataProvider(source: .ymgal, session: session)
            ])
            #expect(result.first?.games.isEmpty == true)
            #expect(result.first?.error?.contains(query == "expired" ? "401" : "429") == true)
        }
    }

    @Test(arguments: ["zh-Hans", "zh-Hant", "ja"])
    func vndbPreservesNamesAndChoosesDisplayLanguage(_ language: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VNDBNamesProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let game = try #require(try await PublicGameMetadataProvider(source: .vndb, session: session)
            .search(language).first)
        #expect(game.originalTitle == "夏の物語")
        #expect(game.titleLanguage == language)
        #expect(game.title == (language == "zh-Hans" ? "夏日物语" : language == "zh-Hant" ? "夏日物語" : "夏の物語"))
        for title in ["Natsu no Monogatari", "夏の物語", "夏日故事", "Summer Story"] {
            #expect(game.matchingTitles.contains(title))
        }
        let displayed = game.usingLibraryTitle("夏日故事 汉化版 v1.2")
        #expect(displayed.title == (language == "ja" ? "夏日故事" : game.title))
        #expect(displayed.originalTitle == "夏の物語")
        #expect(displayed.sourceID == game.sourceID)
        #expect(displayed.matchingTitles.contains(game.title))
        #expect(game.usingLibraryTitle("夏の物語").title == game.title)
    }

    @Test func olderMetadataSnapshotsRemainReadable() throws {
        let game = GameMetadata(source: .vndb, sourceID: "v1", title: "Older")
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(game)) as? [String: Any])
        json.removeValue(forKey: "alternateTitles")
        json.removeValue(forKey: "titleLanguage")
        let restored = try JSONDecoder().decode(GameMetadata.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored.matchingTitles == ["Older"])
        #expect(restored.usingLibraryTitle("本地名称").title == "Older")
    }

    @Test func invalidJSONIsNotAnEmptyResult() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetadataInvalidProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let results = await GameMetadataSearch.search("game", providers: [
            PublicGameMetadataProvider(source: .bangumi, session: session)
        ])
        #expect(results.first?.error != nil)
    }
}

private final class MetadataFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: String
        switch request.url?.host {
        case "api.bgm.tv":
            body = #"{"data":[{"id":1,"name":"Original","name_cn":"作品","summary":"简介","images":{"large":"https://example.org/cover.jpg"}}]}"#
        case "api.vndb.org":
            body = #"{"results":[{"id":"v1","title":"Original","titles":[{"lang":"zh-Hans","title":"作品"}],"developers":[{"name":"Studio","original":null}],"image":{"url":"https://example.org/cover.jpg"}}]}"#
        case "www.ymgal.games":
            if request.url?.path == "/oauth/token" {
                body = #"{"access_token":"fixture-token"}"#
            } else if request.url?.path == "/open/archive" {
                body = #"{"success":true,"code":0,"data":{"game":{"gid":9007199254740993,"name":"Original","chineseName":"作品","introduction":"完整简介","mainImg":"https://example.org/cover.jpg"}}}"#
            } else {
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token",
                      request.value(forHTTPHeaderField: "version") == "1" else {
                    client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
                    return
                }
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "keyword" }?.value
                if query == "rate-limit" || query == "expired" {
                    body = query == "expired"
                        ? #"{"success":false,"code":401,"msg":"expired"}"#
                        : #"{"success":false,"code":429,"msg":"rate limited"}"#
                } else {
                    body = #"{"success":true,"code":0,"data":{"result":[{"id":"9007199254740993","name":"Original","chineseName":"作品","orgName":"Studio","mainImg":"https://example.org/cover.jpg"}]}}"#
                }
            }
        default:
            body = #"{"items":[{"id":1,"name":"作品"}]}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class MetadataInvalidProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("not JSON".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct FixtureProvider: GameMetadataProvider {
    let source: GameMetadataSource
    let fails: Bool
    func search(_ query: String) async throws -> [GameMetadata] {
        if fails { throw URLError(.timedOut) }
        return [GameMetadata(source: source, sourceID: "1", title: query)]
    }
}

private final class VNDBNamesProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let body: Data
            if let data = request.httpBody { body = data }
            else if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var data = Data()
                var bytes = [UInt8](repeating: 0, count: 2048)
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    guard count > 0 else { break }
                    data.append(contentsOf: bytes.prefix(count))
                }
                body = data
            } else { throw URLError(.badServerResponse) }
            let payload = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            let fields = payload["fields"] as! String
            guard ["alttitle", "aliases", "titles.latin", "titles.main"].allSatisfy(fields.contains) else {
                throw URLError(.badServerResponse)
            }
            let language = (payload["filters"] as! [String])[2]
            var titles: [[String: Any]] = [
                ["lang": "ja", "title": "夏の物語", "latin": "Natsu no Monogatari", "main": true],
                ["lang": "en", "title": "Summer Story", "latin": NSNull(), "main": false]
            ]
            if language != "ja" { titles.append(["lang": "zh-Hant", "title": "夏日物語", "main": false]) }
            if language == "zh-Hans" { titles.append(["lang": "zh-Hans", "title": "夏日物语", "main": false]) }
            let result: [String: Any] = ["results": [[
                "id": "v123", "title": "Natsu no Monogatari", "alttitle": "夏の物語",
                "aliases": ["夏日故事"], "titles": titles
            ]]]
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: result))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
