//
//  PublicGameMetadataProvider+Characters.swift
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

extension PublicGameMetadataProvider {
    public func fetchCharacters(for candidate: GameMetadata) async throws -> [GameCharacter] {
        try await networkAccess()
        guard candidate.source == source else { return [] }
        guard source == .vndb || source == .bangumi else { return [] }
        let sourceID = candidate.sourceID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return try await gatekeeper.characters(sourceID) {
            try await fetchCharactersWithRetry {
                switch source {
                case .vndb: try await fetchVNDBCharacters(for: sourceID)
                case .bangumi: try await fetchBangumiCharacters(for: sourceID)
                case .ymgal, .steam, .hikarinagi, .nextmoe: []
                }
            }
        }
    }

    func fetchCharactersWithRetry(
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

    func request<T: Decodable>(
        _ url: URL, body: Data? = nil, timeout: TimeInterval = 20, as type: T.Type
    ) async throws -> T {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("Maltoria/1.0 (game metadata)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let preparedRequest = request
        let data = try await transportGate.paced {
            try await networkAccess()
            let (data, response) = try await session.data(for: preparedRequest)
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
            return data
        }
        return try JSONDecoder().decode(type, from: data)
    }

    func fetchVNDBCharacters(for sourceID: String) async throws -> [GameCharacter] {
        let cleanID = sourceID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let vndbURL = URL(string: "https://api.vndb.org/kana/vn") else { throw URLError(.badURL) }
        let voiceActorPage = try await request(
            vndbURL, body: vndbVoiceActorQuery(sourceID: cleanID), timeout: 45, as: VNDBNovelVAPage.self
        )
        let voiceActorCharacters = makeGameCharacters(from: voiceActorPage)
        guard voiceActorCharacters.isEmpty else { return voiceActorCharacters }

        guard let characterURL = URL(string: "https://api.vndb.org/kana/character") else { return [] }
        let characterPage = try await request(
            characterURL, body: vndbCharacterQuery(sourceID: cleanID), timeout: 45, as: VNDBCharInfoPage.self
        )
        return makeGameCharacters(from: characterPage, sourceID: cleanID)
    }

    func fetchBangumiCharacters(for sourceID: String) async throws -> [GameCharacter] {
        let cleanID = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "https://api.bgm.tv/v0/subjects/\(cleanID)/characters") else { return [] }
        let list = try await request(url, timeout: 45, as: [BangumiCharacterFull].self)
        return list.map { char in
            let voiceActor = char.actors?.compactMap { actor -> String? in
                let name = actor.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : name
            }.joined(separator: ", ")

            return GameCharacter(
                id: String(char.id),
                name: char.name,
                originalName: nil,
                role: char.relation,
                imageURL: char.images?.large ?? char.images?.medium ?? char.images?.common ?? char.images?.grid,
                pageURL: URL(string: "https://bgm.tv/character/\(char.id)"),
                voiceActor: (voiceActor?.isEmpty == false) ? voiceActor : nil,
                summary: char.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}

private func vndbVoiceActorQuery(sourceID: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "filters": ["id", "=", sourceID],
        "fields": "id, title, va{note, character{id, name, original, description, image.url}, "
            + "staff{id, name, original}}"
    ])
}

private func vndbCharacterQuery(sourceID: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "filters": ["vn", "=", ["id", "=", sourceID]],
        "fields": "id, name, original, description, image.url, vns.id, vns.role"
    ])
}

private func makeGameCharacters(from page: VNDBNovelVAPage) -> [GameCharacter] {
    guard let voiceActors = page.results.first?.voiceActors else { return [] }
    var seenIDs = Set<String>()
    return voiceActors.compactMap { item in
        guard let character = item.character, seenIDs.insert(character.id).inserted else { return nil }
        let name = character.original.flatMap { $0.isEmpty ? nil : $0 } ?? character.name
        let originalName = (character.original?.isEmpty == false && character.name != character.original)
            ? character.name
            : nil
        let voiceActor = item.staff.flatMap { ($0.original?.isEmpty == false) ? $0.original : $0.name }
        return GameCharacter(
            id: character.id,
            name: name,
            originalName: originalName,
            role: item.note,
            imageURL: character.image?.url,
            pageURL: URL(string: "https://vndb.org/\(character.id)"),
            voiceActor: voiceActor,
            summary: PublicGameMetadataProvider.cleanBBCode(character.description)
        )
    }
}

private func makeGameCharacters(from page: VNDBCharInfoPage, sourceID: String) -> [GameCharacter] {
    var seenIDs = Set<String>()
    return page.results.compactMap { character in
        guard seenIDs.insert(character.id).inserted else { return nil }
        let name = character.original.flatMap { $0.isEmpty ? nil : $0 } ?? character.name
        let originalName = (character.original?.isEmpty == false && character.name != character.original)
            ? character.name
            : nil
        return GameCharacter(
            id: character.id,
            name: name,
            originalName: originalName,
            role: character.vns?.first(where: { $0.id == sourceID })?.role,
            imageURL: character.image?.url,
            pageURL: URL(string: "https://vndb.org/\(character.id)"),
            voiceActor: nil,
            summary: PublicGameMetadataProvider.cleanBBCode(character.description)
        )
    }
}
