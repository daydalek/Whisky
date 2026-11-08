//
//  NextMoeTests.swift
//  WhiskyMetadataTests
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
import WhiskyCore
@testable import WhiskyMetadata
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("NextMoe catalog")
struct NextMoeTests {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NextMoeFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test func searchMapsCatalogAndDetailsPage() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let provider = PublicGameMetadataProvider(source: .nextmoe, session: session, networkAccess: {})
        let results = try await provider.search("测试 & 日本語")
        let game = try #require(results.first)
        #expect(game.sourceID == "4")
        #expect(game.title == "中文标题")
        #expect(game.originalTitle == "原題")
        #expect(game.summary == "中文简介")
        #expect(game.developer == "开发商")
        #expect(game.releaseDate == "2026-01-01")
        #expect(game.coverURL?.absoluteString == "https://fixture.example/cover.webp")
        #expect(game.matchingTitles.contains("别名"))
        let detail = try await provider.details(for: game, includeCharacters: true)
        let characters = try #require(detail.characters)
        #expect(characters.count == 2)
        #expect(characters[0].id == "7935")
        #expect(characters[0].name == "鸣濑白羽")
        #expect(characters[0].originalName == "鳴瀬しろは")
        #expect(characters[0].voiceActor == "小原好美 / 第二声优")
        #expect(characters[0].role == "主角")
        #expect(characters[0].imageURL?.absoluteString == "https://fixture.example/character.webp")
        #expect(characters[1].name == "无配音角色")
        #expect(characters[1].voiceActor == nil)
        #expect(characters[1].imageURL == nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GameMetadataStore(directory: directory, networkAccess: {})
        try await store.save(detail, for: "game")
        #expect(try await store.load(for: "game") == GameMetadataRecord(legacy: detail).resolved().metadata)
    }

    @Test func rateLimitCarriesRetryAfterForTheSharedGate() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let provider = NextMoeProvider(session: session, networkAccess: {})
        do {
            _ = try await provider.details(GameMetadata(source: .nextmoe, sourceID: "99", title: "x"))
            Issue.record("Expected rate limit")
        } catch let ProviderError.rateLimited(code, retryAfter) {
            #expect(code == 429)
            #expect(retryAfter == 120)
        }
    }

    @Test func detailQueriesAndCacheKeysRespectCharacterPreference() async throws {
        CharacterPreferenceProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CharacterPreferenceProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let provider = PublicGameMetadataProvider(source: .nextmoe, session: session, networkAccess: {})
        let candidate = GameMetadata(source: .nextmoe, sourceID: "4", title: "Test")
        let without = try await provider.details(for: candidate, includeCharacters: false)
        let with = try await provider.details(for: candidate, includeCharacters: true)
        #expect(without.characters == nil)
        #expect(with.characters?.count == 1)
        #expect(CharacterPreferenceProtocol.characterFlags == [false, true])
    }
}

private final class CharacterPreferenceProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var flags: [Bool] = []

    static var characterFlags: [Bool] { lock.withLock { flags } }
    static func reset() { lock.withLock { flags = [] } }
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        let isWork = url.path.hasSuffix("/works/4")
        let includesCharacters = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "include" }?.value?.contains("characters") == true
        if isWork {
            Self.lock.withLock { Self.flags.append(includesCharacters) }
        }
        let work = includesCharacters
            ? #"{"id":"4","display_name":"Test","localized":{},"characters":[{"id":"1","display_name":"Character"}]}"#
            : #"{"id":"4","display_name":"Test","localized":{}}"#
        let body = isWork ? Data(work.utf8) : Data(#"{"items":[],"next_cursor":null}"#.utf8)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class NextMoeFixtureProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            let url = try #require(request.url)
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") })
            #expect(url.host == "api.nextmoe.dev")
            #expect(query["nsfw"] == "true")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            var status = 200
            let body: [String: Any]
            switch url.path {
            case "/v2/catalog/works":
                #expect(query["q"] == "测试 & 日本語")
                #expect(query["content_limit"] == "sfw")
                body = ["object": "list", "items": [Self.work]]
            case "/v2/catalog/works/4":
                #expect(query["include"]?.split(separator: ",").contains("characters") == true)
                body = Self.work
            case "/v2/catalog/works/99":
                status = 429
                body = ["status": 429, "code": "RATE_LIMITED"]
            default: throw URLError(.badURL)
            }
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Retry-After": "120"]
            ))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            try client?.urlProtocol(self, didLoad: JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    static var work: [String: Any] { [
        "object": "work", "id": "4", "display_name": "原題", "localized": ["zh-Hans": ["value": "中文标题"]],
        "release_date": "2026-01-01", "cover": ["url": "https://fixture.example/cover.webp"],
        "titles": [["title": "别名"]], "intros": [["lang": "zh-Hans", "value": "中文简介"]],
        "characters": [
            [
                "id": "7935",
                "display_name": "鳴瀬しろは",
                "localized": ["zh-Hans": ["value": "鸣濑白羽"]],
                "roster_role": "main",
                "image": ["url": "https://fixture.example/character.webp"],
                "voices": [["display_name": "小原好美"], ["display_name": "第二声优"]]
            ],
            ["id": "2", "display_name": "无配音角色", "voices": []]
        ],
        "companies": [
            ["display_name": "发行商", "attribution_role": "publisher"],
            ["display_name": "开发商", "attribution_role": "developer"]
        ]
    ] }
}
