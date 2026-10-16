// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// These identifiers describe remote works, never executables or Wine settings.
public enum GameMetadataSource: String, Codable, CaseIterable, Sendable, Identifiable {
    case bangumi, vndb, steam, ymgal, hikarinagi

    public var id: String { rawValue }

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
    public var pageURL: URL?
    /// Optional fields keep snapshots written by older app versions readable.
    public var alternateTitles: [String]?
    public var titleLanguage: String?
    public var fetchedAt: Date

    public var id: String { "\(source.rawValue):\(sourceID)" }

    public init(source: GameMetadataSource, sourceID: String, title: String,
                originalTitle: String = "", summary: String = "", developer: String = "",
                releaseDate: String = "", coverURL: URL? = nil, pageURL: URL? = nil,
                fetchedAt: Date = Date(), alternateTitles: [String]? = nil, titleLanguage: String? = nil) {
        self.source = source
        self.sourceID = sourceID
        self.title = title
        self.originalTitle = originalTitle
        self.summary = summary
        self.developer = developer
        self.releaseDate = releaseDate
        self.coverURL = coverURL
        self.pageURL = pageURL
        self.fetchedAt = fetchedAt
        self.alternateTitles = alternateTitles
        self.titleLanguage = titleLanguage
    }

    public var matchingTitles: [String] {
        ([title, originalTitle] + (alternateTitles ?? [])).filter { !$0.isEmpty }
    }

    /// Keep a useful local Chinese display name when VNDB only supplies another
    /// language. All remote names remain available for matching and provenance.
    public func usingLibraryTitle(_ localName: String) -> GameMetadata {
        guard source == .vndb, let titleLanguage, !titleLanguage.hasPrefix("zh") else { return self }
        let local = FolderGameMatching.query(localName)
        guard local.unicodeScalars.contains(where: { (0x3400...0x9fff).contains($0.value) }),
              !local.unicodeScalars.contains(where: { (0x3040...0x30ff).contains($0.value) }) else { return self }
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
            for await result in group { results.append(result) }
            return results.sorted { $0.source.rawValue < $1.source.rawValue }
        }
    }
}
