import Foundation
import Testing
import WhiskyCore
@testable import WhiskyMetadata
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("NextMoe catalog and walkthroughs")
struct NextMoeTests {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NextMoeFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test func searchMapsCatalogAndDetailsPageGuidesWithoutDownloadingCharts() async throws {
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
        let detail = try await provider.details(for: game)
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
        #expect(detail.walkthroughs?.map(\.id) == ["1", "2"])
        #expect(detail.walkthroughs?.allSatisfy { $0.chart == nil } == true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GameMetadataStore(directory: directory, networkAccess: {})
        try await store.save(detail, for: "game")
        #expect(try await store.load(for: "game") == GameMetadataRecord(legacy: detail).resolved().metadata)
    }

    @Test func lazyChartRetainsGraphTranslationsAndFutureStepKindsThroughDisk() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let guide = try await NextMoeProvider(session: session, networkAccess: {}).walkthrough(id: "1", workID: "4")
        #expect(guide.sourceAuthor == "作者")
        #expect(guide.sourceURL?.absoluteString == "https://fixture.example/guide")
        let encoded = try JSONEncoder().encode(guide)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let chart = try #require(json["chart"] as? [String: Any])
        let segments = try #require(chart["segments"] as? [[String: Any]])
        let steps = try #require(segments.first?["steps"] as? [[String: Any]])
        #expect(steps.last?["step_type"] as? String == "future-kind")
        #expect(steps.last?["future_field"] as? String == "preserved")
        let game = GameMetadata(source: .nextmoe, sourceID: "4", title: "测试", walkthroughs: [guide])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GameMetadataStore(directory: directory, networkAccess: {})
        try await store.save(game, for: "game")
        #expect(try await store.load(for: "game") == GameMetadataRecord(legacy: game).resolved().metadata)
    }

    @Test func walkthroughIndexCanBeFetchedWithoutWorkDetails() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let provider = NextMoeProvider(session: session, networkAccess: {})
        let guides = try await provider.walkthroughs(workID: "4")
        #expect(guides.map(\.id) == ["1", "2"])
        #expect(guides.allSatisfy { $0.chart == nil && $0.workID == "4" })
        await #expect(throws: URLError.self) { try await provider.walkthroughs(workID: "../4") }
    }

    @Test func chartChecksWorkIdentityIDsAndNetworkPolicy() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let provider = NextMoeProvider(session: session, networkAccess: {})
        await #expect(throws: URLError.self) { try await provider.walkthrough(id: "1", workID: "5") }
        await #expect(throws: URLError.self) { try await provider.walkthrough(id: "../1", workID: "4") }
        let offline = NextMoeProvider(session: session, networkAccess: { throw URLError(.notConnectedToInternet) })
        await #expect(throws: URLError.self) { try await offline.walkthrough(id: "1", workID: "4") }
    }

    @Test func rateLimitCarriesRetryAfterForTheSharedGate() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await NextMoeProvider(session: session, networkAccess: {}).walkthrough(id: "99", workID: "4")
            Issue.record("Expected rate limit")
        } catch let ProviderError.rateLimited(code, retryAfter) {
            #expect(code == 429)
            #expect(retryAfter == 120)
        }
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
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
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
            case "/v2/catalog/walkthroughs":
                #expect(query["work_id"] == "4")
                #expect(query["content_limit"] == "sfw")
                var guide = Self.guide
                guide.removeValue(forKey: "chart")
                if query["cursor"] == "cur_next" {
                    guide["id"] = "2"
                    body = ["object": "list", "items": [guide]]
                } else {
                    body = ["object": "list", "items": [guide], "next_cursor": "cur_next"]
                }
            case "/v2/catalog/walkthroughs/1": body = Self.guide
            case "/v2/catalog/walkthroughs/99":
                status = 429
                body = ["status": 429, "code": "RATE_LIMITED"]
            default: throw URLError(.badURL)
            }
            let response = try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                                        headerFields: ["Retry-After": "120"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    static var work: [String: Any] { [
        "object": "work", "id": "4", "display_name": "原題", "localized": ["zh-Hans": ["value": "中文标题"]],
        "release_date": "2026-01-01", "cover": ["url": "https://fixture.example/cover.webp"],
        "titles": [["title": "别名"]], "intros": [["lang": "zh-Hans", "value": "中文简介"]],
        "characters": [
            ["id": "7935", "display_name": "鳴瀬しろは", "localized": ["zh-Hans": ["value": "鸣濑白羽"]],
             "roster_role": "main", "image": ["url": "https://fixture.example/character.webp"],
             "voices": [["display_name": "小原好美"], ["display_name": "第二声优"]]],
            ["id": "2", "display_name": "无配音角色", "voices": []]
        ],
        "companies": [["display_name": "发行商", "attribution_role": "publisher"],
                      ["display_name": "开发商", "attribution_role": "developer"]]
    ] }

    static var guide: [String: Any] { [
        "object": "walkthrough", "id": "1", "work_id": "4", "source": "example", "lang": "ja",
        "source_url": "https://fixture.example/guide", "source_author": "作者", "source_updated_on": "2026-01-01",
        "characters": [], "ending_count": 2, "save_count": 1, "segment_count": 2,
        "work_route_hints": true, "work_content_limit": "sfw", "updated_at": "2026-01-01T00:00:00Z",
        "chart": ["sections": [["key": "s1", "title": "路线一"]], "entries": [["key": "start", "label": "开始"]],
                  "saves": [["key": "sv1", "label": "SAVE 1"]], "endings": [["key": "e1", "name": "END"]],
                  "segments": [["key": "g1", "section_key": "s1", "from_node": ["node_type": "entry", "key": "start"],
                                "to_node": ["node_type": "ending", "key": "e1"],
                                "steps": [["step_type": "save", "save_key": "sv1"],
                                          ["step_type": "choice", "text": "選択", "localized": ["zh-Hans": ["value": "选择", "is_machine": true]]],
                                          ["step_type": "future-kind", "future_field": "preserved"]]]]]
    ] }
}
