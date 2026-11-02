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

/// Direct public APIs, including the documented YMGal public OAuth client.
public struct PublicGameMetadataProvider: GameMetadataProvider {
    public let source: GameMetadataSource
    let session: URLSession
    let networkAccess: MetadataNetworkAccess
    private let ymgalClient: YMGalClient
    let gatekeeper: SourceGatekeeper
    let transportGate: SourceGatekeeper

    public init(
        source: GameMetadataSource,
        session: URLSession = .shared,
        networkAccess: @escaping MetadataNetworkAccess,
        transportMinimumInterval: TimeInterval? = nil
    ) {
        self.source = source
        self.networkAccess = networkAccess
        self.session = session
        let isShared = session === URLSession.shared
        self.ymgalClient = isShared ? .shared : YMGalClient(session: session, minInterval: 0)
        self.gatekeeper = isShared ? SourceGatekeeper.shared(for: source) : SourceGatekeeper(minInterval: 0)
        if isShared, transportMinimumInterval == nil {
            self.transportGate = SourceGatekeeper.sharedTransport(for: source)
        } else {
            self.transportGate = SourceGatekeeper(minInterval: transportMinimumInterval ?? 0)
        }
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
        case .nextmoe:
            return try await gatekeeper.search(cacheKey) {
                try await NextMoeProvider(session: session, networkAccess: networkAccess).search(query)
            }
        case .hikarinagi:
            throw ProviderError.directAPIUnavailable
        }
    }

    /// Steam's search endpoint only returns identity and thumbnails. Fetch the
    /// selected item's details, rather than issuing ten extra requests per search.
    public func details(for candidate: GameMetadata, includeCharacters: Bool = false) async throws -> GameMetadata {
        try await networkAccess()
        guard candidate.source == source else { throw URLError(.badURL) }
        if source == .nextmoe {
            let cacheID = "\(candidate.sourceID):characters=\(includeCharacters)"
            return try await gatekeeper.details(cacheID) {
                try await NextMoeProvider(session: session, networkAccess: networkAccess)
                    .details(candidate, includeCharacters: includeCharacters)
            }
        }
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

    /// Refresh only an explicitly confirmed identity, never a title search.
    public func refresh(sourceID: String, includeCharacters: Bool = true) async throws -> GameMetadata {
        try await networkAccess()
        switch source {
        case .bangumi:
            return try await refreshBangumi(sourceID: sourceID, includeCharacters: includeCharacters)
        case .vndb:
            return try await refreshVNDB(sourceID: sourceID, includeCharacters: includeCharacters)
        case .steam:
            return try await refreshSteam(sourceID: sourceID)
        case .ymgal:
            return try await refreshYMGal(sourceID: sourceID)
        case .nextmoe:
            return try await refreshNextMoe(sourceID: sourceID, includeCharacters: includeCharacters)
        case .hikarinagi:
            throw ProviderError.directAPIUnavailable
        }
    }

    private func refreshBangumi(sourceID: String, includeCharacters: Bool) async throws -> GameMetadata {
        guard UInt64(sourceID) != nil,
              let url = URL(string: "https://api.bgm.tv/v0/subjects/\(sourceID)")
        else {
            throw URLError(.badURL)
        }
        return try await gatekeeper.details("\(sourceID):characters=\(includeCharacters)") {
            let subject = try await request(url, as: BangumiSubject.self)
            var game = GameMetadata(
                source: .bangumi, sourceID: String(subject.id),
                title: subject.nameCN.flatMap { $0.isEmpty ? nil : $0 } ?? subject.name,
                originalTitle: subject.name, summary: subject.summary ?? "",
                releaseDate: subject.date ?? "", coverURL: subject.images?.large,
                thumbnailURL: subject.images?.common,
                pageURL: URL(string: "https://bgm.tv/subject/\(subject.id)")
            )
            if includeCharacters {
                game.characters = try await fetchCharactersWithRetry {
                    try await fetchBangumiCharacters(for: String(subject.id))
                }
            }
            return game
        }
    }

    private func refreshVNDB(sourceID: String, includeCharacters: Bool) async throws -> GameMetadata {
        guard sourceID.range(of: #"^v[0-9]+$"#, options: .regularExpression) != nil else {
            throw URLError(.badURL)
        }
        return try await gatekeeper.details("\(sourceID):characters=\(includeCharacters)") {
            guard var game = try await vndb(sourceID).first(where: { $0.sourceID == sourceID }) else {
                throw URLError(.resourceUnavailable)
            }
            if includeCharacters {
                game.characters = try await fetchCharactersWithRetry {
                    try await fetchVNDBCharacters(for: sourceID)
                }
            }
            return game
        }
    }

    private func refreshSteam(sourceID: String) async throws -> GameMetadata {
        try await details(for: GameMetadata(
            source: source, sourceID: sourceID, title: "",
            coverURL: URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(sourceID)/library_600x900.jpg"),
            pageURL: URL(string: "https://store.steampowered.com/app/\(sourceID)")
        ))
    }

    private func refreshYMGal(sourceID: String) async throws -> GameMetadata {
        try await details(for: GameMetadata(source: source, sourceID: sourceID, title: ""))
    }

    private func refreshNextMoe(sourceID: String, includeCharacters: Bool) async throws -> GameMetadata {
        try await details(
            for: GameMetadata(source: source, sourceID: sourceID, title: ""),
            includeCharacters: includeCharacters
        )
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

    public static func parseRetryAfter(_ header: String?) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespacesAndNewlines), !header.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(header), seconds.isFinite, seconds >= 0 {
            return max(seconds, 1)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: header) {
            let delta = date.timeIntervalSinceNow
            return delta > 0 ? delta : nil
        }
        return nil
    }
}

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
