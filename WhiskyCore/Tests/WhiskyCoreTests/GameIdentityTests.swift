//
//  GameIdentityTests.swift
//  WhiskyCoreTests
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

@Test func canonicalGameDatabaseLoadsAndMatchesSteamAndExecutableIdentities() throws {
    let entries = try GameDatabaseResource.identities(in: GameDatabaseResource.data())
    #expect(entries.count >= 83)
    let steam = try #require(GameIdentityMatcher.bestMatch(
        metadata: .init(exeName: "launcher.exe", steamAppId: 1_245_620),
        against: entries
    ))
    #expect(steam.entry.id == "elden-ring")
    #expect(steam.confidence == 1 && steam.tier == .hardIdentifier)
    let exe = try #require(GameIdentityMatcher.match(
        metadata: .init(exeName: "AOE2DE_S.EXE", installPath: "/Games/AoE2DE"),
        against: entries
    ).first)
    #expect(exe.entry.id == "aoe2-de" && exe.confidence == 0.90)
    #expect(GameIdentityMatcher.searchEntries("TW3", in: entries).contains { $0.id == "the-witcher-3" })
}

@Test func identityScoringPreservesFingerprintGenericPenaltyAndAmbiguity() throws {
    let timestamp = Date(timeIntervalSince1970: 1_234)
    let first = GameIdentityRecord(
        id: "one",
        title: "Example Game",
        exeNames: ["game.exe"],
        exeFingerprints: [.init(fileSize: 100, peTimestamp: timestamp)],
        pathPatterns: ["example"]
    )
    let second = GameIdentityRecord(id: "two", title: "Another Game", exeNames: ["game.exe"])
    let fingerprint = try #require(GameIdentityMatcher.bestMatch(metadata: .init(
        exeName: "game.exe",
        fileSize: 100,
        peTimestamp: timestamp
    ), against: [
        first,
        second
    ]))
    #expect(fingerprint.index == 0 && fingerprint.confidence == 0.95)
    let generic = GameIdentityMatcher.match(metadata: .init(exeName: "game.exe"), against: [first, second])
    #expect(generic.count == 2 && abs(generic[0].confidence - 0.55) < 0.001)
    #expect(GameIdentityMatcher.bestMatch(metadata: .init(exeName: "game.exe"), against: [first, second]) == nil)
    let fuzzy = try #require(GameIdentityMatcher.match(metadata: .init(exeName: "Example-Full.exe"), against: [first])
        .first)
    #expect(fuzzy.tier == .fuzzy && fuzzy.confidence >= 0.3 && fuzzy.confidence <= 0.69)
}

@Test func databaseValidationRejectsDuplicateIDsAndUnsupportedVersions() throws {
    for document in [
        #"{"version":2,"entries":[]}"#,
        #"{"version":1,"entries":[{"id":"same","title":"One"},{"id":"same","title":"Two"}]}"#,
        #"{"version":1,"entries":[{"id":"","title":"Empty"}]}"#
    ] {
        #expect(throws: (any Error).self) { try GameDatabaseResource.identities(in: Data(document.utf8)) }
    }
}

@Test func databaseResourceSurvivesRelocationAndReportsMissingFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("game-db-包-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = root.appendingPathComponent("initial")
    let resource = initial.appendingPathComponent("WhiskyCore_WhiskyCore.resources")
    try FileManager.default.createDirectory(at: resource, withIntermediateDirectories: true)
    let data = try GameDatabaseResource.data()
    try data.write(to: resource.appendingPathComponent("GameDB.json"))
    let moved = root.appendingPathComponent("moved %f")
    try FileManager.default.moveItem(at: initial, to: moved)
    #expect(try GameDatabaseResource.data(searchDirectories: [moved]) == data)
    #expect(throws: (any Error).self) { try GameDatabaseResource.data(searchDirectories: [initial]) }
}
