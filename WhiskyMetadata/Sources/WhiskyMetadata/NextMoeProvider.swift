//
//  NextMoeProvider.swift
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

/// Public catalog reads use anonymous access. No application secret ships in the desktop bundle.
public struct NextMoeProvider: Sendable {
    private static let requestGate = SourceGatekeeper(minInterval: 2.1)
    let session: URLSession
    let networkAccess: MetadataNetworkAccess

    public init(session: URLSession = .shared, networkAccess: @escaping MetadataNetworkAccess) {
        self.session = session
        self.networkAccess = networkAccess
    }

    public func search(_ query: String) async throws -> [GameMetadata] {
        let page: Page<Work> = try await get("works", [
            "q": query, "limit": "8", "include": "titles,intros,companies", "content_limit": "sfw"
        ])
        return page.items.map { $0.metadata() }
    }

    public func details(_ candidate: GameMetadata, includeCharacters: Bool = true) async throws -> GameMetadata {
        guard candidate.source == .nextmoe, Self.validID(candidate.sourceID) else { throw URLError(.badURL) }
        var includes = "titles,intros,companies"
        if includeCharacters { includes += ",characters" }
        let work: Work = try await get("works/\(candidate.sourceID)", ["include": includes])
        return work.metadata()
    }

    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.allSatisfy { (48 ... 57).contains($0) }
    }

    private func get<T: Decodable & Sendable>(_ path: String, _ parameters: [String: String] = [:]) async throws -> T {
        let operation: @Sendable () async throws -> T = {
            try await networkAccess()
            try Task.checkCancellation()
            guard var url = URLComponents(string: "https://api.nextmoe.dev/v2/catalog/\(path)") else {
                throw URLError(.badURL)
            }
            var query = parameters
            query["nsfw"] = "true"
            url.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let requestURL = url.url else { throw URLError(.badURL) }
            var request = URLRequest(url: requestURL, timeoutInterval: 25)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Maltoria/1.0 (NextMoe catalog)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200 ..< 300).contains(http.statusCode) else {
                if http.statusCode == 429 || http.statusCode == 503 {
                    throw ProviderError.rateLimited(
                        http.statusCode,
                        retryAfter:
                        PublicGameMetadataProvider.parseRetryAfter(http.value(forHTTPHeaderField: "Retry-After")) ?? 60
                    )
                }
                throw ProviderError.http(http.statusCode)
            }
            try Task.checkCancellation()
            return try JSONDecoder().decode(T.self, from: data)
        }
        if session === URLSession.shared { return try await Self.requestGate.paced(operation: operation) }
        return try await operation()
    }
}

private struct Page<T: Decodable & Sendable>: Decodable, Sendable {
    let items: [T]
    let nextCursor: String?
    enum CodingKeys: String, CodingKey { case items
        case nextCursor = "next_cursor"
    }
}

private struct Work: Decodable, Sendable {
    struct Text: Decodable, Sendable { let value: String }
    struct Image: Decodable, Sendable { let url: URL }
    struct Intro: Decodable, Sendable { let lang: String
        let value: String
    }

    struct Title: Decodable, Sendable { let title: String }

    let id: String
    let displayName: String
    let localized: [String: Text]
    let releaseDate: String?
    let cover: Image?
    let titles: [Title]?
    let intros: [Intro]?
    let companies: [WorkCompany]?
    let characters: [WorkCharacter]?

    enum CodingKeys: String, CodingKey {
        case id, localized, cover, titles, intros, companies, characters
        case displayName = "display_name", releaseDate = "release_date"
    }

    func metadata() -> GameMetadata {
        let intro = intros?.first { $0.lang == "zh-Hans" } ?? intros?.first { $0.lang == "ja" } ?? intros?.first
        return GameMetadata(
            source: .nextmoe, sourceID: id,
            title: localized["zh-Hans"]?.value ?? localized["zh"]?.value ?? displayName,
            originalTitle: displayName, summary: intro?.value ?? "",
            developer: (companies ?? []).filter { $0.attributionRole == "developer" }.map(\.displayName)
                .joined(separator: ", "),
            releaseDate: releaseDate ?? "", coverURL: cover?.url,
            alternateTitles: (titles ?? []).map(\.title) + localized.values.map(\.value),
            characters: characters?.map { $0.metadata() }
        )
    }
}

private struct WorkCharacterVoice: Decodable, Sendable {
    let displayName: String

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }
}

private struct WorkCompany: Decodable, Sendable {
    let displayName: String
    let attributionRole: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case attributionRole = "attribution_role"
    }
}

private struct WorkCharacter: Decodable, Sendable {
    let id: String
    let displayName: String
    let localized: [String: Work.Text]?
    let rosterRole: String?
    let image: Work.Image?
    let figure: Work.Image?
    let voices: [WorkCharacterVoice]?

    enum CodingKeys: String, CodingKey {
        case id, localized, image, figure, voices
        case displayName = "display_name"
        case rosterRole = "roster_role"
    }

    func metadata() -> GameCharacter {
        let names = (voices ?? []).map(\.displayName).filter { !$0.isEmpty }
        let role = rosterRole.map { role in
            switch role {
            case "main": "主角"
            case "secondary": "配角"
            case "appears": "客串"
            default: role
            }
        }
        return GameCharacter(
            id: id,
            name: localized?["zh-Hans"]?.value ?? localized?["zh"]?.value ?? displayName,
            originalName: displayName,
            role: role,
            imageURL: image?.url ?? figure?.url,
            voiceActor: names.isEmpty ? nil : names.joined(separator: " / ")
        )
    }
}
