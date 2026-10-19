//
//  GameActivityTransactionTests.swift
//  WhiskyKit
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

struct GameActivityTransactionTests {
    private func makeEntry(bottle: URL, name: String = "game.exe") -> LibraryEntry {
        LibraryEntry(
            id: name,
            name: name,
            iconURL: nil,
            bottleURL: bottle,
            source: .pinned,
            launch: .program(bottle.appendingPathComponent("drive_c/" + name))
        )
    }

    // swiftlint:disable:next function_body_length
    @Test func ownershipHandoffAndIdempotentSamples() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = GameActivityStore()
        let entry = makeEntry(bottle: tempDir)

        let guiOwnerID = UUID()
        let workerOwnerID = UUID()

        // GUI acquires ownership
        let guiOwner = try store.acquireOwnership(
            for: entry,
            source: .gui,
            ownerID: guiOwnerID
        )
        #expect(guiOwner.generation == 1)
        #expect(guiOwner.source == .gui)

        // GUI submits sample sequence 1
        let now = Date()
        let res1 = try store.recordSample(
            seconds: 15,
            at: now,
            for: entry,
            ownerID: guiOwnerID,
            generation: 1,
            sequence: 1
        )
        #expect(res1 == .applied(playTime: 15))

        // Duplicate submission of same sequence is idempotent
        let res1Dup = try store.recordSample(
            seconds: 15,
            at: now,
            for: entry,
            ownerID: guiOwnerID,
            generation: 1,
            sequence: 1
        )
        #expect(res1Dup == .alreadyApplied)
        #expect(try store.load(for: entry).playTime == 15)

        // Worker takes over ownership
        let workerOwner = try store.acquireOwnership(
            for: entry,
            source: .worker,
            ownerID: workerOwnerID
        )
        #expect(workerOwner.generation == 2)
        #expect(workerOwner.source == .worker)

        // Old GUI owner attempts to submit sample with generation 1 -> rejected with ownershipChanged
        let staleGUI = try store.recordSample(
            seconds: 10,
            at: now.addingTimeInterval(5),
            for: entry,
            ownerID: guiOwnerID,
            generation: 1,
            sequence: 2
        )
        if case let .ownershipChanged(current) = staleGUI {
            #expect(current?.ownerID == workerOwnerID)
            #expect(current?.generation == 2)
        } else {
            Issue.record("Expected ownershipChanged result")
        }

        // Playtime is still 15
        #expect(try store.load(for: entry).playTime == 15)

        // Worker submits sequence 1
        let workerRes = try store.recordSample(
            seconds: 30,
            at: now.addingTimeInterval(10),
            for: entry,
            ownerID: workerOwnerID,
            generation: 2,
            sequence: 1
        )
        #expect(workerRes == .applied(playTime: 45))
        #expect(try store.load(for: entry).playTime == 45)

        // Setting rating preserves ownership and playtime
        try store.setRating(9, for: entry)
        let afterRating = try store.load(for: entry)
        #expect(afterRating.rating == 9)
        #expect(afterRating.playTime == 45)
        #expect(afterRating.owner?.ownerID == workerOwnerID)
        #expect(afterRating.owner?.generation == 2)
    }

    @Test func backwardCompatibleDecodingWithoutOwner() throws {
        let json = """
        {
            "playTime": 120.5,
            "rating": 7,
            "lastPlayed": 1000000
        }
        """
        let decoded = try JSONDecoder().decode(GameActivity.self, from: Data(json.utf8))
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.playTime == 120.5)
        #expect(decoded.rating == 7)
        #expect(decoded.owner == nil)
        #expect(decoded.lastAppliedSample == nil)
    }
}
