//
//  GameActivityDailyTests.swift
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

@Suite("Daily play history")
struct GameActivityDailyTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .current
        return value
    }

    @Test func splitsMidnightAndPreservesCumulativeHistory() throws {
        let end = try #require(calendar.date(from: DateComponents(year: 2_026, month: 10, day: 30, minute: 10)))
        var activity = GameActivity()
        activity.playTime = 1_000
        #expect(activity.record(1_200, at: end) == true)
        #expect(activity.playTime == 2_200)
        #expect(activity.dailyPlayTime == ["2026-10-29": 600, "2026-10-30": 600])
        let restored = try JSONDecoder().decode(GameActivity.self, from: JSONEncoder().encode(activity))
        #expect(restored == activity)
    }

    @Test func wholeCalendarDaysUseTheirActualDuration() throws {
        let start = try #require(calendar.date(from: DateComponents(year: 2_026, month: 3, day: 8)))
        let end = try #require(calendar.date(byAdding: .day, value: 1, to: start))
        let seconds = end.timeIntervalSince(start)
        var activity = GameActivity()
        activity.record(seconds, at: end)
        #expect(activity.dailyPlayTime == ["2026-03-08": seconds])
        #expect(activity.playTime == seconds)
    }

    @Test func legacyRecordsHaveNoInventedDailyHistory() throws {
        let activity = try JSONDecoder().decode(GameActivity.self, from: Data(#"{"playTime":3600}"#.utf8))
        #expect(activity.playTime == 3_600)
        #expect(activity.dailyPlayTime.isEmpty)
    }

    @Test func sampleRetriesCannotDoubleCountDailyHistory() throws {
        var activity = GameActivity()
        let owner = try activity.acquireOwnership(
            source: .gui, ownerID: UUID(), process: HostProcessIdentity(pid: 123, birth: 1), isAlive: { _ in false }
        )
        let token = GameActivitySampleToken(ownerID: owner.ownerID, generation: owner.generation, sequence: 1)
        let date = Date()
        #expect(activity.recordSample(seconds: 60, at: date, token: token) == .applied(playTime: 60))
        let before = activity.dailyPlayTime
        #expect(activity.recordSample(seconds: 60, at: date, token: token) == .alreadyApplied)
        #expect(activity.dailyPlayTime == before)
        #expect(activity.record(0, at: date) == true)
        #expect(activity.dailyPlayTime == before)
        for seconds in [-1, Double.nan, .infinity] {
            #expect(activity.record(seconds, at: date) == false)
        }
        #expect(activity.dailyPlayTime == before)
    }
}
