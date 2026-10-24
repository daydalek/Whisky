//
//  MetadataMatchingTests.swift
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
import Testing
@testable import WhiskyCore

@Suite("Portable metadata matching")
struct MetadataMatchingTests {
    @Test func nameCleanupRetainsSubtitles() {
        #expect(FolderGameMatching.query("星之终途 汉化版 v1.2") == "星之终途")
        #expect(FolderGameMatching.query("Game (Another Story)") == "Game (Another Story)")
        #expect(FolderGameMatching.query("[测试汉化组] 夏日物语 官方中文版 v1.2") == "夏日物语")
        #expect(FolderGameMatching.query("[230526][新新汉化] 苍之彼方的四重奏 免安装绿色版 Ver1.02 [CHS]") == "苍之彼方的四重奏")
        #expect(FolderGameMatching.query("Game 2 Build 1024") == "Game 2")
        #expect(FolderGameMatching.query("[Another Story] Game") == "[Another Story] Game")
        #expect(FolderGameMatching.normalized("ＧＡＭＥ: One") == "gameone")
        #expect(FolderGameMatching.normalized("櫻之詩 桜の詩") == "樱之诗樱の诗")
    }

    @Test func canonicalEditionsAndShinjitaiMatchAcrossSources() {
        let sequel = GameMetadata(source: .vndb, sourceID: "v2", title: "WHITE ALBUM 2")
        let remake = GameMetadata(source: .bangumi, sourceID: "10", title: "Summer Story Remake")
        let results = [
            GameMetadataSearchResult(source: .vndb, games: [sequel], error: nil),
            GameMetadataSearchResult(source: .bangumi, games: [remake], error: nil)
        ]
        #expect(FolderGameMatching.candidate(
            query: "White Album II", results: results, sources: [.vndb, .bangumi]
        ) == sequel)
        #expect(FolderGameMatching.candidate(
            query: "Summer Story 重制版", results: results, sources: [.vndb, .bangumi]
        ) == remake)
    }

    @Test func onlyUniqueExactNamesAreAutomaticallyMatched() {
        let exact = GameMetadata(source: .bangumi, sourceID: "1", title: "Game")
        let other = GameMetadata(source: .bangumi, sourceID: "2", title: "Game 2")
        let result = GameMetadataSearchResult(source: .bangumi, games: [exact, other], error: nil)
        #expect(FolderGameMatching.candidate(query: "game", results: [result], sources: [.bangumi]) == exact)
        #expect(FolderGameMatching.candidate(query: "gam", results: [result], sources: [.bangumi]) == nil)
        let duplicate = GameMetadataSearchResult(source: .bangumi, games: [exact, exact], error: nil)
        #expect(FolderGameMatching.candidate(query: "Game", results: [duplicate], sources: [.bangumi]) == nil)
    }

    @Test func matchesEveryAliasAndTraditionalChinese() {
        let game = GameMetadata(
            source: .vndb,
            sourceID: "v1",
            title: "Romanized",
            originalTitle: "日本語",
            alternateTitles: ["夏日物語", "Summer Tale"]
        )
        let results = [GameMetadataSearchResult(source: .vndb, games: [game], error: nil)]
        for query in ["夏日物语", "Summer Tale", "日本語", "Romanized"] {
            #expect(FolderGameMatching.candidate(query: query, results: results, sources: [.vndb]) == game)
        }
    }

    @Test func longTypoMatchesWhileCloseAlternativesAndEditionsRequireConfirmation() {
        let title = "A Wonderful Summer Story"
        let game = GameMetadata(source: .vndb, sourceID: "v1", title: title)
        func candidate(_ query: String, games: [GameMetadata] = []) -> GameMetadata? {
            FolderGameMatching.candidate(query: query, results: [
                GameMetadataSearchResult(source: .vndb, games: games.isEmpty ? [game] : games, error: nil)
            ], sources: [.vndb])
        }
        #expect(candidate("A Wonderfull Summer Story") == game)
        for query in [title + " 2", title + " II", title + " FD", title + "+", title + " Complete"] {
            #expect(candidate(query) == nil, "Edition query: \(query)")
        }
        let close = GameMetadata(source: .vndb, sourceID: "v2", title: "A Wonderful Summer Stori")
        #expect(candidate("A Wonderfull Summer Story", games: [close, game]) == nil)
        #expect(FolderGameMatching.ranked(query: title, games: [close, game]).first == game)
    }

    @Test func exactLaterSourceWinsAndFailedSourcesAllowFallback() {
        let close = GameMetadata(source: .bangumi, sourceID: "1", title: "A Wonderfull Summer Story")
        let exact = GameMetadata(source: .vndb, sourceID: "v1", title: "A Wonderful Summer Story")
        for error in [nil, "HTTP 500"] {
            let results = [
                GameMetadataSearchResult(source: .bangumi, games: [close], error: error),
                GameMetadataSearchResult(source: .vndb, games: [exact], error: nil)
            ]
            #expect(FolderGameMatching.candidate(
                query: exact.title,
                results: results,
                sources: [.bangumi, .vndb]
            ) == exact)
        }
    }
}
