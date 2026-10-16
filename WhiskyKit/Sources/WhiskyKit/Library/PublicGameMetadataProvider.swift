// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Direct public APIs, including the documented YMGal public OAuth client.
public struct PublicGameMetadataProvider: GameMetadataProvider {
    public let source: GameMetadataSource
    private let session: URLSession
    private let ymgalClient: YMGalClient

    public init(source: GameMetadataSource, session: URLSession = .shared) {
        self.source = source
        self.session = session
        self.ymgalClient = session === URLSession.shared ? .shared : YMGalClient(session: session)
    }

    public func search(_ query: String) async throws -> [GameMetadata] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        switch source {
        case .bangumi: return try await bangumi(query)
        case .vndb: return try await vndb(query)
        case .steam: return try await steam(query)
        case .ymgal: return try await ymgalClient.search(query)
        case .hikarinagi: throw ProviderError.directAPIUnavailable
        }
    }

    /// Steam's search endpoint only returns identity and thumbnails. Fetch the
    /// selected item's details, rather than issuing ten extra requests per search.
    public func details(for candidate: GameMetadata) async throws -> GameMetadata {
        guard candidate.source == source else { throw URLError(.badURL) }
        if source == .ymgal { return try await ymgalClient.details(candidate) }
        guard source == .steam else { return candidate }
        guard Int(candidate.sourceID) != nil else { throw URLError(.badURL) }
        var components = URLComponents(string: "https://store.steampowered.com/api/appdetails")!
        components.queryItems = [
            URLQueryItem(name: "appids", value: candidate.sourceID),
            URLQueryItem(name: "l", value: "schinese")
        ]
        let response = try await request(components.url!, as: [String: SteamDetailResponse].self)
        guard let result = response[candidate.sourceID], result.success, let data = result.data else {
            throw URLError(.resourceUnavailable)
        }
        var game = candidate
        game.title = data.name
        game.summary = data.short_description ?? ""
        game.developer = data.developers?.joined(separator: ", ") ?? ""
        game.releaseDate = data.release_date?.date ?? ""
        game.fetchedAt = Date()
        return game
    }

    private func request<T: Decodable>(
        _ url: URL, body: Data? = nil, as type: T.Type
    ) async throws -> T {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Whisky/1.0 (game metadata)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(response.statusCode) else {
            throw ProviderError.http(response.statusCode)
        }
        try Task.checkCancellation()
        return try JSONDecoder().decode(type, from: data)
    }

    private func bangumi(_ query: String) async throws -> [GameMetadata] {
        let body = try JSONSerialization.data(withJSONObject: [
            "keyword": query, "filter": ["type": [4]]
        ])
        let result = try await request(
            URL(string: "https://api.bgm.tv/v0/search/subjects?limit=10")!,
            body: body, as: BangumiResponse.self
        )
        return result.data.map { game in
            GameMetadata(
                source: .bangumi, sourceID: String(game.id),
                title: game.name_cn?.isEmpty == false ? game.name_cn! : game.name,
                originalTitle: game.name, summary: game.summary ?? "",
                releaseDate: game.date ?? "", coverURL: game.images?.large,
                pageURL: URL(string: "https://bgm.tv/subject/\(game.id)")
            )
        }
    }

    private func vndb(_ query: String) async throws -> [GameMetadata] {
        let body = try JSONSerialization.data(withJSONObject: [
            "filters": ["search", "=", query],
            "fields": "title,alttitle,aliases,titles.title,titles.lang,titles.latin,titles.main,description,image.url,developers.name,developers.original,released",
            "sort": "searchrank", "results": 10
        ])
        let result = try await request(
            URL(string: "https://api.vndb.org/kana/vn")!, body: body, as: VNDBResponse.self
        )
        return result.results.map { game in
            let titles = (game.titles ?? []).filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let preferred = ["zh-Hans", "zh", "zh-Hant"].compactMap { language in
                titles.first { $0.lang == language }
            }.first ?? titles.first { $0.main == true }
            let original = titles.first { $0.main == true }?.title
                ?? game.alttitle.flatMap { $0.isEmpty ? nil : $0 } ?? game.title
            let names = [game.title, game.alttitle ?? ""] + titles.map(\.title)
                + titles.compactMap(\.latin) + (game.aliases ?? [])
            return GameMetadata(
                source: .vndb, sourceID: game.id, title: preferred?.title ?? original,
                originalTitle: original, summary: game.description ?? "",
                developer: game.developers?.map { $0.original ?? $0.name }.joined(separator: ", ") ?? "",
                releaseDate: game.released ?? "", coverURL: game.image?.url,
                pageURL: URL(string: "https://vndb.org/\(game.id)"),
                alternateTitles: Array(Set(names.filter { !$0.isEmpty })).sorted(),
                titleLanguage: preferred?.lang ?? "und"
            )
        }
    }

    private func steam(_ query: String) async throws -> [GameMetadata] {
        var components = URLComponents(string: "https://store.steampowered.com/api/storesearch/")!
        components.queryItems = [
            URLQueryItem(name: "term", value: query), URLQueryItem(name: "l", value: "schinese"),
            URLQueryItem(name: "cc", value: "us")
        ]
        let result = try await request(components.url!, as: SteamResponse.self)
        return result.items.prefix(10).map { game in
            GameMetadata(
                source: .steam, sourceID: String(game.id), title: game.name,
                coverURL: URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(game.id)/library_600x900.jpg"),
                pageURL: URL(string: "https://store.steampowered.com/app/\(game.id)")
            )
        }
    }
}

private enum ProviderError: LocalizedError {
    case http(Int)
    case directAPIUnavailable

    var errorDescription: String? {
        switch self {
        case .http(let code): return "HTTP \(code)"
        case .directAPIUnavailable:
            return "Hikarinagi: a direct official API has not been verified. Third-party proxies are not used."
        }
    }
}

private struct BangumiResponse: Decodable {
    let data: [Subject]
    struct Subject: Decodable {
        let id: Int
        let name: String
        let name_cn: String?
        let summary: String?
        let date: String?
        let images: Images?
    }
    struct Images: Decodable { let large: URL? }
}

private struct VNDBResponse: Decodable {
    let results: [Novel]
    struct Novel: Decodable {
        let id: String
        let title: String
        let titles: [Title]?
        let alttitle: String?
        let aliases: [String]?
        let description: String?
        let released: String?
        let image: Image?
        let developers: [Developer]?
    }
    struct Title: Decodable {
        let title: String
        let lang: String
        let latin: String?
        let main: Bool?
    }
    struct Image: Decodable { let url: URL? }
    struct Developer: Decodable { let name: String; let original: String? }
}

private struct SteamResponse: Decodable {
    let items: [Item]
    struct Item: Decodable { let id: Int; let name: String }
}

private struct SteamDetailResponse: Decodable {
    let success: Bool
    let data: Details?
    struct Details: Decodable {
        let name: String
        let short_description: String?
        let developers: [String]?
        let release_date: ReleaseDate?
    }
    struct ReleaseDate: Decodable { let date: String? }
}

/// One request at a time across the app, including token refresh. The public
/// client is published at https://www.ymgal.games/developer (non-commercial use).
private actor YMGalClient {
    static let shared = YMGalClient(session: .shared)
    private let session: URLSession
    private var token: String?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var searches: [String: (Date, [GameMetadata])] = [:]
    private var games: [String: GameMetadata] = [:]

    init(session: URLSession) { self.session = session }

    private func acquire() async throws {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else { busy = true }
        do { try Task.checkCancellation() } catch { release(); throw error }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    func search(_ query: String) async throws -> [GameMetadata] {
        try await acquire()
        defer { release() }
        guard query.count < 96 else { throw YMGalError(code: 614, message: "查询关键词需少于 96 个字符") }
        if let cached = searches[query], Date().timeIntervalSince(cached.0) < 300 { return cached.1 }
        let page: Page = try await api("/open/archive/search-game", parameters: [
            "mode": "list", "keyword": query, "pageNum": "1", "pageSize": "10"
        ])
        let results = page.result.map { $0.metadata() }
        if searches.count >= 50 { searches.removeAll() }
        searches[query] = (Date(), results)
        return results
    }

    func details(_ candidate: GameMetadata) async throws -> GameMetadata {
        try await acquire()
        defer { release() }
        if let cached = games[candidate.sourceID] { return cached }
        guard UInt64(candidate.sourceID) != nil else { throw URLError(.badURL) }
        let detail: Detail = try await api("/open/archive", parameters: ["gid": candidate.sourceID])
        var result = detail.game.metadata(id: candidate.sourceID)
        result.developer = candidate.developer
        if games.count >= 100 { games.removeAll() }
        games[candidate.sourceID] = result
        return result
    }

    private func api<T: Decodable>(_ path: String, parameters: [String: String]) async throws -> T {
        for attempt in 0..<2 {
            if token == nil {
                let response: Token = try await fetch("/oauth/token", parameters: [
                    "grant_type": "client_credentials", "client_id": "ymgal",
                    "client_secret": "luna0327", "scope": "public"
                ], authenticated: false)
                guard !response.access_token.isEmpty else { throw URLError(.userAuthenticationRequired) }
                token = response.access_token
            }
            do {
                let response: Envelope<T> = try await fetch(path, parameters: parameters, authenticated: true)
                guard response.success, response.code == 0 else {
                    throw YMGalError(code: response.code, message: response.msg ?? "请求失败")
                }
                guard let value = response.data else { throw URLError(.cannotParseResponse) }
                return value
            } catch {
                let expired: Bool
                if case ProviderError.http(401) = error { expired = true }
                else if let error = error as? YMGalError { expired = error.code == 401 }
                else { expired = false }
                guard expired, attempt == 0 else { throw error }
                token = nil
            }
        }
        throw URLError(.userAuthenticationRequired)
    }

    private func fetch<T: Decodable>(_ path: String, parameters: [String: String], authenticated: Bool) async throws -> T {
        try Task.checkCancellation()
        var url = URLComponents(string: "https://www.ymgal.games" + path)!
        url.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url.url!, timeoutInterval: 20)
        request.setValue("application/json;charset=utf-8", forHTTPHeaderField: "Accept")
        request.setValue("Whisky/1.0 (game metadata)", forHTTPHeaderField: "User-Agent")
        if authenticated {
            request.setValue("Bearer \(token!)", forHTTPHeaderField: "Authorization")
            request.setValue("1", forHTTPHeaderField: "version")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else { throw ProviderError.http(http.statusCode) }
        try Task.checkCancellation()
        return try JSONDecoder().decode(T.self, from: data)
    }

    private struct Token: Decodable { let access_token: String }
    private struct Envelope<T: Decodable>: Decodable {
        let success: Bool
        let code: Int
        let msg: String?
        let data: T?
    }
    private struct Page: Decodable { let result: [Game] }
    private struct Detail: Decodable { let game: Game }
    private struct Game: Decodable {
        let id: Identifier?
        let name: String
        let chineseName: String?
        let introduction: String?
        let mainImg: String?
        let orgName: String?
        let releaseDate: String?

        func metadata(id fallback: String = "") -> GameMetadata {
            let identifier = id?.value ?? fallback
            return GameMetadata(
                source: .ymgal, sourceID: identifier,
                title: chineseName?.isEmpty == false ? chineseName! : name,
                originalTitle: name, summary: introduction ?? "", developer: orgName ?? "",
                releaseDate: releaseDate ?? "", coverURL: mainImg.flatMap(URL.init(string:)),
                pageURL: URL(string: "https://www.ymgal.games/ga\(identifier)")
            )
        }
    }
    private struct Identifier: Decodable {
        let value: String
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) { value = string }
            else { value = String(try container.decode(Int64.self)) }
        }
    }
}

private struct YMGalError: LocalizedError {
    let code: Int
    let message: String
    var errorDescription: String? { "月幕 Galgame (\(code)): \(message)" }
}
