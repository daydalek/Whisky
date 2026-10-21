//
//  GameActivityPortabilityTests.swift
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

@Suite("Portable activity transactions")
struct GameActivityPortabilityTests {
    private let process = HostProcessIdentity(pid: 123, birth: 456)
    private let date = Date(timeIntervalSince1970: 100)

    @Test func legacyJSONAndOwnerFieldsRoundTrip() throws {
        let legacy = Data(#"{"playTime":120.5,"rating":7,"lastPlayed":1000000}"#.utf8)
        let decoded = try JSONDecoder().decode(GameActivity.self, from: legacy)
        #expect(decoded.schemaVersion == 1 && decoded.ownershipGeneration == 0)
        #expect(decoded.playTime == 120.5 && decoded.rating == 7)
        #expect(decoded.owner == nil && decoded.lastSessionEndedAt == nil)
        var activity = decoded
        let owner = try activity.acquireOwnership(
            source: .gui,
            ownerID: UUID(),
            process: process,
            isAlive: { _ in false }
        )
        let data = try JSONEncoder().encode(activity)
        #expect(try JSONDecoder().decode(GameActivity.self, from: data) == activity)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let ownerJSON = try #require(json["owner"] as? [String: Any])
        #expect(Set(ownerJSON.keys) == ["source", "ownerID", "hostPID", "hostProcessBirth", "generation"])
        #expect(ownerJSON["hostPID"] as? Int == Int(process.pid))
        #expect(owner.process == process)
        var old = json
        old.removeValue(forKey: "ownershipGeneration")
        let restored = try JSONDecoder().decode(GameActivity.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(restored.ownershipGeneration == owner.generation)
    }

    @Test func liveOwnerHandoffFollowsWorkerPriority() throws {
        let sources: [GameActivityOwner.Source] = [.gui, .worker, .cli]
        for current in sources {
            for requested in sources {
                var activity = GameActivity()
                let initial = try activity.acquireOwnership(
                    source: current, ownerID: UUID(), process: process, isAlive: { _ in false }
                )
                let before = activity
                if requested == .worker, current != .worker {
                    let next = try activity.acquireOwnership(
                        source: requested, ownerID: UUID(), process: process, isAlive: { _ in true }
                    )
                    #expect(next.generation == 2 && next.source == .worker)
                } else {
                    #expect(throws: GameActivityOwnershipError.heldByLiveOwner(initial)) {
                        try activity.acquireOwnership(
                            source: requested, ownerID: UUID(), process: process, isAlive: { _ in true }
                        )
                    }
                    #expect(activity == before)
                }
            }
        }
    }

    @Test func reacquiringAndRecycledPIDRespectProcessBirth() throws {
        var activity = GameActivity()
        let id = UUID()
        let first = try activity.acquireOwnership(source: .gui, ownerID: id, process: process, isAlive: { _ in false })
        var probes = 0
        let same = try activity.acquireOwnership(source: .cli, ownerID: id, process: process, isAlive: { _ in
            probes += 1
            return true
        })
        #expect(same == first && probes == 0)
        let recycled = HostProcessIdentity(pid: process.pid, birth: process.birth + 1)
        let second = try activity.acquireOwnership(source: .gui, ownerID: id, process: recycled, isAlive: { previous in
            #expect(previous == process)
            return false
        })
        #expect(second.generation == 2 && second.process == recycled)
    }

    @Test func sampleRetriesAndStaleOwnersPreserveTime() throws {
        var activity = GameActivity()
        let owner = try activity.acquireOwnership(
            source: .gui,
            ownerID: UUID(),
            process: process,
            isAlive: { _ in false }
        )
        let token = GameActivitySampleToken(ownerID: owner.ownerID, generation: owner.generation, sequence: 2)
        #expect(activity.recordSample(seconds: 15, at: date, token: token) == .applied(playTime: 15))
        let before = activity
        #expect(activity.recordSample(seconds: 15, at: date, token: token) == .alreadyApplied)
        var older = token
        older.sequence = 1
        #expect(activity.recordSample(seconds: 30, at: date, token: older) == .alreadyApplied)
        for invalid in [Double.nan, .infinity, -1] {
            #expect(activity.recordSample(seconds: invalid, at: date, token: token) == .alreadyApplied)
        }
        #expect(activity == before)
        var stale = token
        stale.generation += 1
        #expect(activity.recordSample(seconds: 15, at: date, token: stale) == .ownershipChanged(currentOwner: owner))
        #expect(activity == before)
        var next = token
        next.sequence += 1
        #expect(activity
            .recordSample(seconds: 5, at: date.addingTimeInterval(-10), token: next) == .applied(playTime: 20))
        #expect(activity.lastPlayed == date)
    }

    @Test func completionAndReleaseRequireTheCurrentLease() throws {
        var activity = GameActivity()
        let owner = try activity.acquireOwnership(
            source: .gui,
            ownerID: UUID(),
            process: process,
            isAlive: { _ in false }
        )
        activity.lastSessionEndedAt = date
        activity.lastPlayed = date.addingTimeInterval(10)
        let before = activity
        #expect(activity.completeSession(at: date, ownerID: UUID(), generation: owner.generation) == false)
        #expect(activity.releaseOwnership(ownerID: owner.ownerID, generation: owner.generation + 1) == false)
        #expect(activity == before)
        let completed = activity.completeSession(
            at: date.addingTimeInterval(-10),
            ownerID: owner.ownerID,
            generation: owner.generation
        )
        #expect(completed)
        #expect(activity.lastSessionEndedAt == date && activity.lastPlayed == before.lastPlayed)
        #expect(activity.owner == nil)
        #expect(activity.completeSession(
            at: date.addingTimeInterval(20),
            ownerID: owner.ownerID,
            generation: owner.generation
        ) == false)
        #expect(activity.lastSessionEndedAt == date)
    }

    @Test func copyingHistoryPreservesDestinationSamplesAndOwnership() throws {
        var source = GameActivity()
        source.record(100, at: date)
        try source.setRating(8)
        var target = GameActivity()
        let owner = try target.acquireOwnership(
            source: .worker,
            ownerID: UUID(),
            process: process,
            isAlive: { _ in false }
        )
        let token = GameActivitySampleToken(ownerID: owner.ownerID, generation: owner.generation, sequence: 10)
        #expect(target.recordSample(seconds: 5, at: date, token: token) == .applied(playTime: 5))
        var copied = source.preservingOwnership(from: target)
        #expect(copied.playTime == 100 && copied.rating == 8)
        #expect(copied.owner == owner && copied.ownershipGeneration == target.ownershipGeneration)
        #expect(copied.recordSample(seconds: 5, at: date, token: token) == .alreadyApplied)
        var next = token
        next.sequence += 1
        #expect(copied.recordSample(seconds: 5, at: date, token: next) == .applied(playTime: 105))
    }

    @Test func ratingAndLegacySamplesKeepIndependentFields() throws {
        var activity = GameActivity()
        activity.record(20, at: date)
        let before = activity
        for invalid in [0, 11] {
            #expect(throws: GameActivityValidationError.ratingOutOfRange) { try activity.setRating(invalid) }
            #expect(activity == before)
        }
        try activity.setRating(10)
        #expect(activity.playTime == 20)
        #expect(activity.record(-1, at: date) == false)
        try activity.setRating(nil)
        #expect(activity == before)
    }

    @Test func clockUsesMonotonicIntervalsAndResolvesAmbiguousNames() {
        let names: [String: Set<String>] = ["a": ["game.exe"], "b": ["game.exe"], "c": ["unique.exe"]]
        #expect(GameActivityClock.match(executables: names, runningNames: ["game.exe"]).isEmpty)
        #expect(GameActivityClock.match(
            executables: names, runningNames: ["game.exe", "unique.exe"], preferred: ["game.exe": "b"]
        ) == ["b", "c"])
        var clock = GameActivityClock()
        #expect(clock.sample(running: ["b"], at: date, uptime: 5) == ["b": 0])
        #expect(clock.sample(running: ["b"], at: date.addingTimeInterval(-100), uptime: 10) == ["b": 5])
        #expect(clock.sample(running: ["b"], at: date, uptime: 100) == ["b": 0])
        clock.reset()
        #expect(clock.sample(running: ["b"], at: date, uptime: 110) == ["b": 0])
    }
}
