//
//  PublicGameMetadataProvider+Search.swift
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
extension PublicGameMetadataProvider {
    func bangumi(_ query: String) async throws -> [GameMetadata] {
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

    func vndb(_ query: String) async throws -> [GameMetadata] {
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

    func steam(_ query: String) async throws -> [GameMetadata] {
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
}
