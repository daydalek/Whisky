//
//  YMGalClient.swift
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

/// One request at a time across the app, including token refresh. The public
/// client is published at https://www.ymgal.games/developer (non-commercial use).
actor YMGalClient {
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
        request.setValue("Maltoria/1.0 (game metadata)", forHTTPHeaderField: "User-Agent")
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
