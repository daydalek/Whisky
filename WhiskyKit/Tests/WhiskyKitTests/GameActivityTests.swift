//
//  GameActivityTests.swift
//  WhiskyKitTests
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
@testable import WhiskyKit

@Suite("Game Activity")
struct GameActivityTests {
    private func entry(bottle: URL, name: String = "game.exe") -> LibraryEntry {
        LibraryEntry(
            id: name,
            name: name,
            iconURL: nil,
            bottleURL: bottle,
            source: .pinned,
            launch: .program(bottle.appendingPathComponent("drive_c/" + name))
        )
    }

    @Test @MainActor
    func ratingAndTimeSurviveReloadAndStayIndependent() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let game = entry(bottle: url)
        let store = GameActivityStore()
        #expect(try store.load(for: game) == GameActivity())
        try store.setRating(8, for: game)
        try store.record(120, at: Date(timeIntervalSince1970: 1_000), for: game)
        try store.record(30, at: Date(timeIntervalSince1970: 1_100), for: game)
        let saved = try GameActivityStore().load(for: game)
        #expect(saved.rating == 8)
        #expect(saved.playTime == 150)
        #expect(saved.lastPlayed == Date(timeIntervalSince1970: 1_100))
        try store.setRating(nil, for: game)
        #expect(try store.load(for: game).rating == nil)
        #expect(try store.load(for: game).playTime == 150)
        #expect(try store.load(for: entry(bottle: url, name: "other.exe")).playTime == 0)
        #expect(throws: (any Error).self) { try store.setRating(11, for: game) }
        #expect(throws: (any Error).self) { try store.setRating(0, for: game) }
        try store.record(.infinity, at: Date(), for: game)
        try store.record(-10, at: Date(), for: game)
        #expect(try store.load(for: game).playTime == 150)
    }

    @Test @MainActor
    func personalRecordsMoveWithBottleAndIgnoreMetadataRemoval() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = entry(bottle: url.appendingPathComponent("source"))
        let target = entry(bottle: url.appendingPathComponent("target"))
        let store = GameActivityStore()
        try store.setRating(9, for: source)
        try store.record(60, at: Date(), for: source)
        try store.copy(from: source, to: target)
        #expect(try store.load(for: source) == store.load(for: target))
        let movedURL = url.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: target.bottleURL, to: movedURL)
        #expect(try store.load(for: entry(bottle: movedURL)).playTime == 60)
        #expect(source.metadataDirectory.lastPathComponent == "Game Metadata")
        #expect(try FileManager.default.contentsOfDirectory(atPath: movedURL.path) == ["Game Activity"])
    }

    @Test
    func matchingRequiresSelectionForSharedExecutableNames() {
        let executables: [String: Set<String>] = ["a": ["game.exe"], "b": ["game.exe"], "c": ["unique.exe"]]
        #expect(GameActivityClock.match(executables: executables, runningNames: ["game.exe"]).isEmpty)
        #expect(GameActivityClock.match(
            executables: executables, runningNames: ["game.exe", "unique.exe"], preferred: ["game.exe": "b"]
        ) == ["b", "c"])
        #expect(GameActivityClock.match(executables: executables, runningNames: ["steam.exe"]).isEmpty)
    }

    @Test
    func clockHandlesStartsStopsFailuresAndSleepGaps() {
        var clock = GameActivityClock()
        func time(_ seconds: Double) -> Date {
            Date(timeIntervalSince1970: seconds)
        }
        #expect(clock.sample(running: [], at: time(0)).isEmpty)
        #expect(clock.sample(running: ["a"], at: time(10)) == ["a": 0])
        #expect(clock.sample(running: ["a", "b"], at: time(20)) == ["a": 10, "b": 0])
        #expect(clock.sample(running: ["b"], at: time(30)) == ["b": 10])
        #expect(clock.sample(running: ["b"], at: time(300)) == ["b": 0])
        #expect(clock.sample(running: ["b"], at: time(290)) == ["b": 0])
        clock = GameActivityClock()
        #expect(clock.sample(running: ["b"], at: time(310)) == ["b": 0])
    }
}
