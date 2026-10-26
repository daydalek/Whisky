//
//  GameMetadata.swift
//  WhiskyCore
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

/// These identifiers describe remote works, never executables or Wine settings.
public enum GameMetadataSource: String, Codable, CaseIterable, Sendable, Identifiable {
    case bangumi, vndb, steam, ymgal, hikarinagi

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .bangumi: "Bangumi"
        case .vndb: "VNDB"
        case .steam: "Steam"
        case .ymgal: "月幕"
        case .hikarinagi: "Hikarinagi"
        }
    }
}

/// A character appearing in a game.
public struct GameCharacter: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var originalName: String?
    public var imageURL: URL?
    public var voiceActor: String?
    public var summary: String?
    public var role: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        originalName: String? = nil,
        imageURL: URL? = nil,
        voiceActor: String? = nil,
        summary: String? = nil,
        role: String? = nil
    ) {
        self.id = id
        self.name = name
        self.originalName = originalName
        self.imageURL = imageURL
        self.voiceActor = voiceActor
        self.summary = summary
        self.role = role
    }
}

/// A complete source snapshot. We deliberately do not merge unconfirmed search
/// results: similarly named releases from different sites may be different works.
public struct GameMetadata: Codable, Hashable, Sendable, Identifiable {
    public let source: GameMetadataSource
    public let sourceID: String
    public var title: String
    public var originalTitle: String
    public var summary: String
    public var developer: String
    public var releaseDate: String
    public var coverURL: URL?
    public var thumbnailURL: URL?
    public var pageURL: URL?
    /// Optional fields keep snapshots written by older app versions readable.
    public var alternateTitles: [String]?
    public var titleLanguage: String?
    public var characters: [GameCharacter]?
    public var fetchedAt: Date

    public var id: String {
        "\(source.rawValue):\(sourceID)"
    }

    public init(
        source: GameMetadataSource,
        sourceID: String,
        title: String,
        originalTitle: String = "",
        summary: String = "",
        developer: String = "",
        releaseDate: String = "",
        coverURL: URL? = nil,
        thumbnailURL: URL? = nil,
        pageURL: URL? = nil,
        fetchedAt: Date = Date(),
        alternateTitles: [String]? = nil,
        titleLanguage: String? = nil,
        characters: [GameCharacter]? = nil
    ) {
        self.source = source
        self.sourceID = sourceID
        self.title = title
        self.originalTitle = originalTitle
        self.summary = summary
        self.developer = developer
        self.releaseDate = releaseDate
        self.coverURL = coverURL
        self.thumbnailURL = thumbnailURL
        self.pageURL = pageURL
        self.fetchedAt = fetchedAt
        self.alternateTitles = alternateTitles
        self.titleLanguage = titleLanguage
        self.characters = characters
    }

    public var matchingTitles: [String] {
        ([title, originalTitle] + (alternateTitles ?? [])).filter { !$0.isEmpty }
    }

    /// Keep a useful local Chinese display name when VNDB only supplies another
    /// language. All remote names remain available for matching and provenance.
    public func usingLibraryTitle(_ localName: String) -> GameMetadata {
        guard source == .vndb, let titleLanguage, !titleLanguage.hasPrefix("zh") else { return self }
        let local = FolderGameMatching.query(localName)
        guard local.unicodeScalars.contains(where: { (0x3400 ... 0x9FFF).contains($0.value) }),
              !local.unicodeScalars.contains(where: {
                  (0x3040 ... 0x30FF).contains($0.value) && $0.value != 0x30FB
              })
        else { return self }
        var result = self
        result.alternateTitles = Array(Set(matchingTitles)).sorted()
        result.title = local
        return result
    }
}

public protocol GameMetadataProvider: Sendable {
    var source: GameMetadataSource { get }
    func search(_ query: String) async throws -> [GameMetadata]
}

public struct GameMetadataSearchResult: Sendable {
    public let source: GameMetadataSource
    public let games: [GameMetadata]
    public let error: String?

    public init(source: GameMetadataSource, games: [GameMetadata], error: String? = nil) {
        self.source = source
        self.games = games
        self.error = error
    }
}

public struct GameMetadataAutomaticMatchOutcome: Sendable {
    public let candidate: GameMetadata?
    public let results: [GameMetadataSearchResult]
    /// True when at least one provider was queried and every queried provider failed with an error.
    public var allProvidersFailed: Bool {
        !results.isEmpty && results.allSatisfy { $0.error != nil }
    }
}

public enum GameMetadataSearch {
    /// Caller chooses the providers. No background scan or implicit library upload.
    public static func search(_ query: String, providers: [any GameMetadataProvider]) async
        -> [GameMetadataSearchResult] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return await withTaskGroup(of: GameMetadataSearchResult.self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        let games = try await provider.search(query)
                        return GameMetadataSearchResult(source: provider.source, games: games, error: nil)
                    } catch {
                        return GameMetadataSearchResult(
                            source: provider.source, games: [], error: error.localizedDescription
                        )
                    }
                }
            }
            var results: [GameMetadataSearchResult] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.source.rawValue < $1.source.rawValue }
        }
    }

    /// Queries providers sequentially in priority order and short-circuits as soon as an
    /// unambiguous exact match (or exact-match ambiguity) is found, minimizing load on remote APIs.
    public static func automaticMatch(_ query: String, providers: [any GameMetadataProvider]) async
        -> GameMetadataAutomaticMatchOutcome {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !providers.isEmpty else {
            return GameMetadataAutomaticMatchOutcome(candidate: nil, results: [])
        }
        var results: [GameMetadataSearchResult] = []
        let sources = providers.map(\.source)
        for provider in providers {
            if Task.isCancelled {
                break
            }
            let result: GameMetadataSearchResult
            do {
                let games = try await provider.search(trimmed)
                result = GameMetadataSearchResult(source: provider.source, games: games, error: nil)
            } catch {
                result = GameMetadataSearchResult(
                    source: provider.source, games: [], error: error.localizedDescription
                )
            }
            results.append(result)
            if result.error == nil {
                let exactMatches = FolderGameMatching.exactMatches(query: trimmed, in: result.games)
                if exactMatches.count == 1 {
                    return GameMetadataAutomaticMatchOutcome(candidate: exactMatches[0], results: results)
                }
                if exactMatches.count > 1 {
                    return GameMetadataAutomaticMatchOutcome(candidate: nil, results: results)
                }
            }
        }
        let candidate = FolderGameMatching.candidate(query: trimmed, results: results, sources: sources)
        return GameMetadataAutomaticMatchOutcome(candidate: candidate, results: results)
    }
}
