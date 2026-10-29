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

    public func details(_ candidate: GameMetadata) async throws -> GameMetadata {
        guard candidate.source == .nextmoe, Self.validID(candidate.sourceID) else { throw URLError(.badURL) }
        let work: Work = try await get("works/\(candidate.sourceID)", ["include": "titles,intros,companies,characters"])
        var metadata = work.metadata()
        var guides: [GameWalkthrough] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            var parameters = ["work_id": work.id, "limit": "100", "content_limit": "sfw"]
            parameters["cursor"] = cursor
            let page: Page<GameWalkthrough> = try await get("walkthroughs", parameters)
            guides.append(contentsOf: page.items)
            cursor = page.nextCursor
            if let cursor, !seen.insert(cursor).inserted { throw URLError(.cannotParseResponse) }
        } while cursor != nil
        metadata.walkthroughs = guides
        return metadata
    }

    public func walkthrough(id: String, workID: String) async throws -> GameWalkthrough {
        guard Self.validID(id), Self.validID(workID) else { throw URLError(.badURL) }
        let guide: GameWalkthrough = try await get("walkthroughs/\(id)")
        guard guide.workID == workID, guide.workContentLimit == "sfw", guide.chart != nil else {
            throw URLError(.cannotParseResponse)
        }
        return guide
    }

    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.allSatisfy { (48...57).contains($0) }
    }

    private func get<T: Decodable & Sendable>(_ path: String, _ parameters: [String: String] = [:]) async throws -> T {
        let operation: @Sendable () async throws -> T = {
            try await networkAccess()
            try Task.checkCancellation()
            var url = URLComponents(string: "https://api.nextmoe.dev/v2/catalog/\(path)")!
            var query = parameters
            query["nsfw"] = "true"
            url.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            var request = URLRequest(url: url.url!, timeoutInterval: 25)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Whisky/1.0 (NextMoe catalog)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 429 || http.statusCode == 503 {
                    throw ProviderError.rateLimited(http.statusCode, retryAfter:
                        PublicGameMetadataProvider.parseRetryAfter(http.value(forHTTPHeaderField: "Retry-After")) ?? 60)
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
    enum CodingKeys: String, CodingKey { case items; case nextCursor = "next_cursor" }
}

private struct Work: Decodable, Sendable {
    struct Text: Decodable, Sendable { let value: String }
    struct Image: Decodable, Sendable { let url: URL }
    struct Intro: Decodable, Sendable { let lang: String; let value: String }
    struct Title: Decodable, Sendable { let title: String }
    struct Company: Decodable, Sendable {
        let displayName: String
        let attributionRole: String?
        enum CodingKeys: String, CodingKey { case displayName = "display_name", attributionRole = "attribution_role" }
    }
    let id: String
    let displayName: String
    let localized: [String: Text]
    let releaseDate: String?
    let cover: Image?
    let titles: [Title]?
    let intros: [Intro]?
    let companies: [Company]?
    let characters: [Character]?

    struct Character: Decodable, Sendable {
        struct Voice: Decodable, Sendable {
            let displayName: String
            enum CodingKeys: String, CodingKey { case displayName = "display_name" }
        }
        let id: String
        let displayName: String
        let localized: [String: Text]?
        let rosterRole: String?
        let image: Image?
        let figure: Image?
        let voices: [Voice]?
        enum CodingKeys: String, CodingKey {
            case id, localized, image, figure, voices
            case displayName = "display_name", rosterRole = "roster_role"
        }

        func metadata() -> GameCharacter {
            let names = (voices ?? []).map(\.displayName).filter { !$0.isEmpty }
            let role = rosterRole.map { role in
                switch role {
                case "main": return "主角"
                case "secondary": return "配角"
                case "appears": return "客串"
                default: return role
                }
            }
            return GameCharacter(
                id: id, name: localized?["zh-Hans"]?.value ?? localized?["zh"]?.value ?? displayName,
                originalName: displayName, imageURL: image?.url ?? figure?.url,
                voiceActor: names.isEmpty ? nil : names.joined(separator: " / "), role: role
            )
        }
    }
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
            developer: (companies ?? []).filter { $0.attributionRole == "developer" }.map(\.displayName).joined(separator: ", "),
            releaseDate: releaseDate ?? "", coverURL: cover?.url,
            alternateTitles: (titles ?? []).map(\.title) + localized.values.map(\.value),
            characters: characters?.map { $0.metadata() }
        )
    }
}
