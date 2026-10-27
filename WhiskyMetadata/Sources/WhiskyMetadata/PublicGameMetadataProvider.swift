// swiftlint:disable file_length
//
//  PublicGameMetadataProvider.swift
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
import WhiskyCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// swiftlint:disable type_body_length
/// Direct public APIs, including the documented YMGal public OAuth client.
public struct PublicGameMetadataProvider: GameMetadataProvider {
    public let source: GameMetadataSource
    private let session: URLSession
    private let networkAccess: MetadataNetworkAccess
    private let ymgalClient: YMGalClient
    private let gatekeeper: SourceGatekeeper

    public init(
        source: GameMetadataSource,
        session: URLSession = .shared,
        networkAccess: @escaping MetadataNetworkAccess
    ) {
        self.source = source
        self.networkAccess = networkAccess
        self.session = session
        let isShared = session === URLSession.shared
        self.ymgalClient = isShared ? .shared : YMGalClient(session: session, minInterval: 0)
        self.gatekeeper = isShared ? SourceGatekeeper.shared(for: source) : SourceGatekeeper(minInterval: 0)
    }

    public func search(_ query: String) async throws -> [GameMetadata] {
        try await networkAccess()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let cacheKey = Self.cacheKey(for: query)
        switch source {
        case .bangumi:
            return try await gatekeeper.search(cacheKey) { try await bangumi(query) }
        case .vndb:
            return try await gatekeeper.search(cacheKey) { try await vndb(query) }
        case .steam:
            return try await gatekeeper.search(cacheKey) { try await steam(query) }
        case .ymgal:
            return try await ymgalClient.search(query, networkAccess: networkAccess)
        case .hikarinagi:
            throw ProviderError.directAPIUnavailable
        }
    }

    /// Steam's search endpoint only returns identity and thumbnails. Fetch the
    /// selected item's details, rather than issuing ten extra requests per search.
    public func details(for candidate: GameMetadata, includeCharacters: Bool = false) async throws -> GameMetadata {
        try await networkAccess()
        guard candidate.source == source else { throw URLError(.badURL) }
        if source == .ymgal {
            return try await ymgalClient.details(candidate, networkAccess: networkAccess)
        }
        if source == .vndb || source == .bangumi {
            var game = candidate
            if includeCharacters, game.characters == nil {
                game.characters = try await fetchCharacters(for: candidate)
            }
            return game
        }
        guard source == .steam else { return candidate }
        guard Int(candidate.sourceID) != nil else { throw URLError(.badURL) }
        return try await gatekeeper.details(candidate.sourceID) {
            guard var components = URLComponents(string: "https://store.steampowered.com/api/appdetails") else {
                throw URLError(.badURL)
            }
            components.queryItems = [
                URLQueryItem(name: "appids", value: candidate.sourceID),
                URLQueryItem(name: "l", value: "schinese")
            ]
            guard let requestURL = components.url else { throw URLError(.badURL) }
            let response = try await request(requestURL, as: [String: SteamDetailResponse].self)
            guard let result = response[candidate.sourceID], result.success, let data = result.data else {
                throw URLError(.resourceUnavailable)
            }
            var game = candidate
            game.title = data.name
            game.summary = data.shortDescription ?? ""
            game.developer = data.developers?.joined(separator: ", ") ?? ""
            game.releaseDate = data.releaseDate?.date ?? ""
            game.fetchedAt = Date()
            return game
        }
    }

    public func fetchCharacters(for candidate: GameMetadata) async throws -> [GameCharacter] {
        try await networkAccess()
        guard candidate.source == source else { return [] }
        guard source == .vndb || source == .bangumi else { return [] }
        let sourceID = candidate.sourceID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return try await gatekeeper.characters(sourceID) {
            try await fetchCharactersWithRetry {
                switch source {
                case .vndb: return try await fetchVNDBCharacters(for: sourceID)
                case .bangumi: return try await fetchBangumiCharacters(for: sourceID)
                case .ymgal, .steam, .hikarinagi: return []
                }
            }
        }
    }

    private func fetchCharactersWithRetry(
        _ operation: () async throws -> [GameCharacter]
    ) async throws -> [GameCharacter] {
        do {
            return try await operation()
        } catch let error as URLError where error.code == .timedOut {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(1))
            return try await operation()
        }
    }

    public static func cacheKey(for query: String) -> String {
        query.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func request<T: Decodable>(
        _ url: URL, body: Data? = nil, timeout: TimeInterval = 20, as type: T.Type
    ) async throws -> T {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("Whisky/1.0 (game metadata)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        try await networkAccess()
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200 ..< 300).contains(response.statusCode) else {
            if response.statusCode == 429 || response.statusCode == 503 {
                throw ProviderError.rateLimited(
                    response.statusCode,
                    retryAfter: Self.parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After"))
                )
            }
            throw ProviderError.http(response.statusCode)
        }
        try Task.checkCancellation()
        return try JSONDecoder().decode(type, from: data)
    }

    public static func parseRetryAfter(_ header: String?) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespacesAndNewlines), !header.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(header), seconds >= 0 {
            return min(max(seconds, 1), 300)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: header) {
            let delta = date.timeIntervalSinceNow
            return delta > 0 ? min(delta, 300) : nil
        }
        return nil
    }

    private func bangumi(_ query: String) async throws -> [GameMetadata] {
        let body = try JSONSerialization.data(withJSONObject: [
            "keyword": query, "filter": ["type": [4]]
        ])
        guard let bangumiURL = URL(string: "https://api.bgm.tv/v0/search/subjects?limit=10") else {
            throw URLError(.badURL)
        }
        let result = try await request(
            bangumiURL,
            body: body, as: BangumiResponse.self
        )
        return result.data.map { game in
            GameMetadata(
                source: .bangumi, sourceID: String(game.id),
                title: (game.nameCN?.isEmpty == false ? game.nameCN : nil) ?? game.name,
                originalTitle: game.name, summary: game.summary ?? "",
                releaseDate: game.date ?? "", coverURL: game.images?.large,
                thumbnailURL: game.images?.common ?? game.images?.medium ?? game.images?.grid ?? game.images?.large,
                pageURL: URL(string: "https://bgm.tv/subject/\(game.id)")
            )
        }
    }

    private func vndb(_ query: String) async throws -> [GameMetadata] {
        let isDirectID = query.range(of: #"^v\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil
        let filter: [Any] = isDirectID ? ["id", "=", query.lowercased()] : ["search", "=", query]
        let body = try JSONSerialization.data(withJSONObject: [
            "filters": filter,
            "fields": [
                "title", "alttitle", "aliases", "titles.title", "titles.lang", "titles.latin",
                "titles.main", "description", "image.url", "developers.name",
                "developers.original", "released"
            ].joined(separator: ","),
            "sort": isDirectID ? "id" : "searchrank", "results": 10
        ])
        guard let vndbURL = URL(string: "https://api.vndb.org/kana/vn") else { throw URLError(.badURL) }
        let result = try await request(
            vndbURL, body: body, as: VNDBResponse.self
        )
        return result.results.map { game in
            let titles = (game.titles ?? []).filter {
                !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
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
        guard var components = URLComponents(string: "https://store.steampowered.com/api/storesearch/") else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(name: "term", value: query), URLQueryItem(name: "l", value: "schinese"),
            URLQueryItem(name: "cc", value: "us")
        ]
        guard let requestURL = components.url else { throw URLError(.badURL) }
        let result = try await request(requestURL, as: SteamResponse.self)
        return result.items.prefix(10).map { game in
            GameMetadata(
                source: .steam, sourceID: String(game.id), title: game.name,
                coverURL: URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(game.id)/library_600x900.jpg"),
                thumbnailURL: game.tinyImage,
                pageURL: URL(string: "https://store.steampowered.com/app/\(game.id)")
            )
        }
    }

    // swiftlint:disable:next function_body_length
    private func fetchVNDBCharacters(for sourceID: String) async throws -> [GameCharacter] {
        let cleanID = sourceID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let body = try JSONSerialization.data(withJSONObject: [
            "filters": ["id", "=", cleanID],
            "fields": "id, title, va{note, character{id, name, original, description, image.url}, "
                + "staff{id, name, original}}"
        ])
        guard let vndbURL = URL(string: "https://api.vndb.org/kana/vn") else { throw URLError(.badURL) }
        let result = try await request(vndbURL, body: body, timeout: 45, as: VNDBNovelVAPage.self)

        var characters: [GameCharacter] = []
        var seenIDs = Set<String>()

        if let novel = result.results.first, let vaList = novel.voiceActors, !vaList.isEmpty {
            for item in vaList {
                guard let char = item.character else { continue }
                if seenIDs.contains(char.id) {
                    continue
                }
                seenIDs.insert(char.id)

                let primaryName = char.original.flatMap { $0.isEmpty ? nil : $0 } ?? char.name
                let subName = (char.original?.isEmpty == false && char.name != char.original) ? char.name : nil
                let voiceActor = item.staff.flatMap { ($0.original?.isEmpty == false) ? $0.original : $0.name }

                characters.append(GameCharacter(
                    id: char.id,
                    name: primaryName,
                    originalName: subName,
                    imageURL: char.image?.url,
                    voiceActor: voiceActor,
                    summary: Self.cleanBBCode(char.description),
                    role: item.note
                ))
            }
        }

        if characters.isEmpty {
            let charBody = try JSONSerialization.data(withJSONObject: [
                "filters": ["vn", "=", ["id", "=", cleanID]],
                "fields": "id, name, original, description, image.url"
            ])
            guard let charURL = URL(string: "https://api.vndb.org/kana/character") else { return [] }
            let charResult = try await request(charURL, body: charBody, timeout: 45, as: VNDBCharacterResponse.self)
            for char in charResult.results {
                if seenIDs.contains(char.id) {
                    continue
                }
                seenIDs.insert(char.id)
                let primaryName = char.original.flatMap { $0.isEmpty ? nil : $0 } ?? char.name
                let subName = (char.original?.isEmpty == false && char.name != char.original) ? char.name : nil
                characters.append(GameCharacter(
                    id: char.id,
                    name: primaryName,
                    originalName: subName,
                    imageURL: char.image?.url,
                    voiceActor: nil,
                    summary: Self.cleanBBCode(char.description),
                    role: nil
                ))
            }
        }
        return characters
    }

    private func fetchBangumiCharacters(for sourceID: String) async throws -> [GameCharacter] {
        let cleanID = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "https://api.bgm.tv/v0/subjects/\(cleanID)/characters") else { return [] }
        let list = try await request(url, timeout: 45, as: [BangumiCharacter].self)
        return list.map { char in
            let voiceActor = char.actors?.compactMap { actor -> String? in
                let name = actor.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : name
            }.joined(separator: ", ")

            return GameCharacter(
                id: String(char.id),
                name: char.name,
                originalName: nil,
                imageURL: char.images?.large ?? char.images?.medium ?? char.images?.common ?? char.images?.grid,
                voiceActor: (voiceActor?.isEmpty == false) ? voiceActor : nil,
                summary: char.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
                role: char.relation
            )
        }
    }

    public static func cleanBBCode(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        var result = text
        result = result.replacingOccurrences(
            of: #"(?i)\[url=[^\]]*\](.*?)\[/url\]"#,
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)\[url\](.*?)\[/url\]"#,
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)\[spoiler\](.*?)\[/spoiler\]"#,
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\[/?[a-zA-Z0-9_-]+(=[^\]]*)?\]"#,
            with: "",
            options: .regularExpression
        )
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// swiftlint:enable type_body_length
enum ProviderError: LocalizedError {
    case http(Int)
    case rateLimited(Int, retryAfter: TimeInterval?)
    case directAPIUnavailable

    var errorDescription: String? {
        switch self {
        case let .http(code), let .rateLimited(code, _): "HTTP \(code)"
        case .directAPIUnavailable:
            "Hikarinagi: a direct official API has not been verified. Third-party proxies are not used."
        }
    }
}

private struct BangumiImages: Decodable {
    let large: URL?
    let common: URL?
    let medium: URL?
    let grid: URL?
}

private struct BangumiSubject: Decodable {
    let id: Int
    let name: String
    let nameCN: String?
    let summary: String?
    let date: String?
    let images: BangumiImages?

    enum CodingKeys: String, CodingKey {
        case id, name, summary, date, images
        case nameCN = "name_cn"
    }
}

private struct BangumiResponse: Decodable {
    let data: [BangumiSubject]
}

private struct VNDBTitle: Decodable {
    let title: String
    let lang: String
    let latin: String?
    let main: Bool?
}

private struct VNDBImage: Decodable { let url: URL? }

private struct VNDBDeveloper: Decodable {
    let name: String
    let original: String?
}

private struct VNDBNovel: Decodable {
    let id: String
    let title: String
    let titles: [VNDBTitle]?
    let alttitle: String?
    let aliases: [String]?
    let description: String?
    let released: String?
    let image: VNDBImage?
    let developers: [VNDBDeveloper]?
}

private struct VNDBResponse: Decodable {
    let results: [VNDBNovel]
}

private struct VNDBVoiceActorItem: Decodable {
    let note: String?
    let character: VNDBCharacter?
    let staff: VNDBStaff?
}

private struct VNDBCharacter: Decodable {
    let id: String
    let name: String
    let original: String?
    let description: String?
    let image: VNDBImage?
}

private struct VNDBStaff: Decodable {
    let id: String
    let name: String
    let original: String?
}

private struct VNDBNovelVA: Decodable {
    let id: String
    let title: String?
    let voiceActors: [VNDBVoiceActorItem]?

    enum CodingKeys: String, CodingKey {
        case id, title
        case voiceActors = "va"
    }
}

private struct VNDBNovelVAPage: Decodable {
    let results: [VNDBNovelVA]
}

private struct VNDBCharacterResponse: Decodable {
    let results: [VNDBCharacter]
}

private struct BangumiCharacterActor: Decodable {
    let id: Int?
    let name: String
}

private struct BangumiCharacter: Decodable {
    let id: Int
    let name: String
    let relation: String?
    let images: BangumiImages?
    let summary: String?
    let actors: [BangumiCharacterActor]?
}

private struct SteamItem: Decodable {
    let id: Int
    let name: String
    let tinyImage: URL?

    enum CodingKeys: String, CodingKey {
        case id, name
        case tinyImage = "tiny_image"
    }
}

private struct SteamResponse: Decodable {
    let items: [SteamItem]
}

private struct SteamReleaseDate: Decodable { let date: String? }

private struct SteamDetails: Decodable {
    let name: String
    let shortDescription: String?
    let developers: [String]?
    let releaseDate: SteamReleaseDate?

    enum CodingKeys: String, CodingKey {
        case name, developers
        case shortDescription = "short_description"
        case releaseDate = "release_date"
    }
}

private struct SteamDetailResponse: Decodable {
    let success: Bool
    let data: SteamDetails?
}

/// Serializes requests per source, caches recent queries/details, paces burst traffic,
/// and honors HTTP 429/503 Retry-After cooldowns so batch syncs do not hammer sites.
public actor SourceGatekeeper {
    private static let bangumi = SourceGatekeeper(minInterval: 0.25)
    private static let vndb = SourceGatekeeper(minInterval: 0.25)
    private static let steam = SourceGatekeeper(minInterval: 0.25)
    private static let fallback = SourceGatekeeper(minInterval: 0)

    static func shared(for source: GameMetadataSource) -> SourceGatekeeper {
        switch source {
        case .bangumi: bangumi
        case .vndb: vndb
        case .steam: steam
        case .ymgal, .hikarinagi: fallback
        }
    }

    private let minInterval: TimeInterval
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var searches: [String: (Date, [GameMetadata])] = [:]
    private var gameDetails: [String: (Date, GameMetadata)] = [:]
    private var characterResults: [String: (Date, [GameCharacter])] = [:]
    private var characterFailures: [String: (Date, any Error)] = [:]
    private var lastRequestAt: Date?
    private var cooldownUntil: (date: Date, code: Int)?

    public init(minInterval: TimeInterval) {
        self.minInterval = minInterval
    }

    private func acquire() async throws {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        do { try Task.checkCancellation() } catch { release()
            throw error
        }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    private func paceAndCheckCooldown() async throws {
        if let cooldown = cooldownUntil {
            if Date() < cooldown.date {
                throw ProviderError.http(cooldown.code)
            }
            cooldownUntil = nil
        }
        if minInterval > 0, let last = lastRequestAt {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < minInterval {
                try await Task.sleep(for: .milliseconds(Int((minInterval - elapsed) * 1_000)))
            }
        }
    }

    private func recordRateLimit(_ code: Int, retryAfter: TimeInterval?) {
        let delay = retryAfter ?? (minInterval > 0 ? 15.0 : 0)
        if delay > 0 {
            cooldownUntil = (Date().addingTimeInterval(delay), code)
        }
    }

    public func search(
        _ key: String,
        operation: @Sendable () async throws -> [GameMetadata]
    ) async throws -> [GameMetadata] {
        try await acquire()
        defer { release() }
        let now = Date()
        if let cached = searches[key], now.timeIntervalSince(cached.0) < 300 {
            return cached.1
        }
        try await paceAndCheckCooldown()
        defer { lastRequestAt = Date() }
        do {
            let results = try await operation()
            Self.insertCache(results, forKey: key, into: &searches, ttl: 300, limit: 64)
            return results
        } catch let ProviderError.rateLimited(code, retryAfter) {
            recordRateLimit(code, retryAfter: retryAfter)
            throw ProviderError.http(code)
        }
    }

    public func details(
        _ id: String,
        operation: @Sendable () async throws -> GameMetadata
    ) async throws -> GameMetadata {
        try await acquire()
        defer { release() }
        let now = Date()
        if let cached = gameDetails[id], now.timeIntervalSince(cached.0) < 600 {
            return cached.1
        }
        try await paceAndCheckCooldown()
        defer { lastRequestAt = Date() }
        do {
            let result = try await operation()
            Self.insertCache(result, forKey: id, into: &gameDetails, ttl: 600, limit: 100)
            return result
        } catch let ProviderError.rateLimited(code, retryAfter) {
            recordRateLimit(code, retryAfter: retryAfter)
            throw ProviderError.http(code)
        }
    }

    /// A serialized, paced operation whose result belongs to the caller's local store.
    public func paced(operation: @Sendable () async throws -> Void) async throws {
        try await acquire()
        defer { release() }
        try await paceAndCheckCooldown()
        defer { lastRequestAt = Date() }
        do {
            try await operation()
        } catch let ProviderError.rateLimited(code, retryAfter) {
            recordRateLimit(code, retryAfter: retryAfter)
            throw ProviderError.http(code)
        }
    }

    /// Coalesce concurrent requests, including empty casts, and damp repeated failed refreshes.
    public func characters(
        _ id: String,
        operation: @Sendable () async throws -> [GameCharacter]
    ) async throws -> [GameCharacter] {
        try await acquire()
        defer { release() }
        if let cached = characterResults[id], Date().timeIntervalSince(cached.0) < 600 {
            return cached.1
        }
        if let failed = characterFailures[id], Date().timeIntervalSince(failed.0) < 30 {
            throw failed.1
        }
        try await paceAndCheckCooldown()
        defer { lastRequestAt = Date() }
        do {
            let result = try await operation()
            Self.insertCache(result, forKey: id, into: &characterResults, ttl: 600, limit: 100)
            characterFailures[id] = nil
            return result
        } catch let ProviderError.rateLimited(code, retryAfter) {
            recordRateLimit(code, retryAfter: retryAfter)
            throw ProviderError.http(code)
        } catch {
            if !Task.isCancelled {
                Self.insertCache(error, forKey: id, into: &characterFailures, ttl: 30, limit: 100)
            }
            throw error
        }
    }

    static func insertCache<Value>(
        _ value: Value, forKey key: String, into cache: inout [String: (Date, Value)],
        ttl: TimeInterval, limit: Int
    ) {
        let now = Date()
        if cache.count >= limit {
            cache = cache.filter { now.timeIntervalSince($0.value.0) < ttl }
            if cache.count >= limit, let oldestKey = cache.min(by: { $0.value.0 < $1.value.0 })?.key {
                cache.removeValue(forKey: oldestKey)
            }
        }
        cache[key] = (now, value)
    }
}

/// One request at a time across the app, including token refresh. The public
/// client is published at https://www.ymgal.games/developer (non-commercial use).
private actor YMGalClient {
    static let shared = YMGalClient(session: .shared, minInterval: 0.25)
    private let session: URLSession
    private let minInterval: TimeInterval
    private var token: String?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var searches: [String: (Date, [GameMetadata])] = [:]
    private var games: [String: (Date, GameMetadata)] = [:]
    private var lastRequestAt: Date?
    private var cooldownUntil: (date: Date, code: Int)?

    init(session: URLSession, minInterval: TimeInterval = 0) {
        self.session = session
        self.minInterval = minInterval
    }

    private func acquire() async throws {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        do { try Task.checkCancellation() } catch { release()
            throw error
        }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    func search(_ query: String, networkAccess: @escaping MetadataNetworkAccess) async throws -> [GameMetadata] {
        try await acquire()
        defer { release() }
        guard query.count < 96 else { throw YMGalError(code: 614, message: "查询关键词需少于 96 个字符") }
        let key = PublicGameMetadataProvider.cacheKey(for: query)
        if let cached = searches[key], Date().timeIntervalSince(cached.0) < 300 {
            return cached.1
        }
        let page: YmgalPage = try await api("/open/archive/search-game", parameters: [
            "mode": "list", "keyword": query, "pageNum": "1", "pageSize": "10"
        ], networkAccess: networkAccess)
        let results = page.result.map { $0.metadata() }
        SourceGatekeeper.insertCache(results, forKey: key, into: &searches, ttl: 300, limit: 64)
        return results
    }

    func details(
        _ candidate: GameMetadata,
        networkAccess: @escaping MetadataNetworkAccess
    ) async throws -> GameMetadata {
        try await acquire()
        defer { release() }
        if let cached = games[candidate.sourceID], Date().timeIntervalSince(cached.0) < 600 {
            return cached.1
        }
        guard UInt64(candidate.sourceID) != nil else { throw URLError(.badURL) }
        let detail: YmgalDetail = try await api(
            "/open/archive",
            parameters: ["gid": candidate.sourceID],
            networkAccess: networkAccess
        )
        var result = detail.game.metadata(id: candidate.sourceID)
        result.developer = candidate.developer
        SourceGatekeeper.insertCache(result, forKey: candidate.sourceID, into: &games, ttl: 600, limit: 100)
        return result
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func api<T: Decodable>(
        _ path: String,
        parameters: [String: String],
        networkAccess: @escaping MetadataNetworkAccess
    ) async throws -> T {
        if let cooldown = cooldownUntil {
            if Date() < cooldown.date {
                throw YMGalError(code: cooldown.code, message: "请求过于频繁，请稍后重试")
            }
            cooldownUntil = nil
        }
        for attempt in 0 ..< 2 {
            if token == nil {
                let response: YmgalToken = try await fetch("/oauth/token", parameters: [
                    "grant_type": "client_credentials", "client_id": "ymgal",
                    "client_secret": "luna0327", "scope": "public"
                ], authenticated: false, networkAccess: networkAccess)
                guard !response.accessToken.isEmpty else { throw URLError(.userAuthenticationRequired) }
                token = response.accessToken
            }
            do {
                let response: YmgalEnvelope<T> = try await fetch(
                    path,
                    parameters: parameters,
                    authenticated: true,
                    networkAccess: networkAccess
                )
                guard response.success, response.code == 0 else {
                    if response.code == 429, minInterval > 0 {
                        cooldownUntil = (Date().addingTimeInterval(15), 429)
                    }
                    throw YMGalError(code: response.code, message: response.msg ?? "请求失败")
                }
                guard let value = response.data else { throw URLError(.cannotParseResponse) }
                return value
            } catch {
                let expired: Bool = if case ProviderError.http(401) = error {
                    true
                } else if let error = error as? YMGalError {
                    error.code == 401
                } else {
                    false
                }
                guard expired, attempt == 0 else { throw error }
                token = nil
            }
        }
        throw URLError(.userAuthenticationRequired)
    }

    private func fetch<T: Decodable>(
        _ path: String,
        parameters: [String: String],
        authenticated: Bool,
        networkAccess: @escaping MetadataNetworkAccess
    ) async throws -> T {
        try Task.checkCancellation()
        if minInterval > 0, let last = lastRequestAt {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < minInterval {
                try await Task.sleep(for: .milliseconds(Int((minInterval - elapsed) * 1_000)))
            }
        }
        guard var url = URLComponents(string: "https://www.ymgal.games" + path) else {
            throw URLError(.badURL)
        }
        url.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let requestURL = url.url else { throw URLError(.badURL) }
        var request = URLRequest(url: requestURL, timeoutInterval: 20)
        request.setValue("application/json;charset=utf-8", forHTTPHeaderField: "Accept")
        request.setValue("Whisky/1.0 (game metadata)", forHTTPHeaderField: "User-Agent")
        if authenticated, let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("1", forHTTPHeaderField: "version")
        }
        defer { lastRequestAt = Date() }
        try await networkAccess()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200 ..< 300).contains(http.statusCode) else {
            if http.statusCode == 429 || http.statusCode == 503 {
                let retryAfter = PublicGameMetadataProvider.parseRetryAfter(
                    http.value(forHTTPHeaderField: "Retry-After")
                ) ?? (minInterval > 0 ? 15.0 : 0)
                if retryAfter > 0 {
                    cooldownUntil = (Date().addingTimeInterval(retryAfter), http.statusCode)
                }
            }
            throw ProviderError.http(http.statusCode)
        }
        try Task.checkCancellation()
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private struct YmgalToken: Decodable {
    let accessToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}

private struct YmgalEnvelope<T: Decodable>: Decodable {
    let success: Bool
    let code: Int
    let msg: String?
    let data: T?
}

private struct YmgalPage: Decodable { let result: [YmgalGame] }
private struct YmgalDetail: Decodable { let game: YmgalGame }

private struct YmgalIdentifier: Decodable {
    let value: String
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else {
            value = try String(container.decode(Int64.self))
        }
    }
}

private struct YmgalGame: Decodable {
    let id: YmgalIdentifier?
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
            title: (chineseName?.isEmpty == false ? chineseName : nil) ?? name,
            originalTitle: name, summary: introduction ?? "", developer: orgName ?? "",
            releaseDate: releaseDate ?? "", coverURL: mainImg.flatMap(URL.init(string:)),
            pageURL: URL(string: "https://www.ymgal.games/ga\(identifier)")
        )
    }
}

private struct YMGalError: LocalizedError {
    let code: Int
    let message: String
    var errorDescription: String? {
        "月幕 Galgame (\(code)): \(message)"
    }
}
