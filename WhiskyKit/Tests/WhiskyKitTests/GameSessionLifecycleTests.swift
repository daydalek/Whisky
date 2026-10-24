//
//  GameSessionLifecycleTests.swift
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

import CryptoKit
import Darwin
import Foundation
import Testing
@testable import WhiskyKit

@MainActor
struct GameSessionLifecycleTests {
    private func fixture() throws -> (URL, LibraryEntry) {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let entry = LibraryEntry(
            id: UUID().uuidString, name: "Game", iconURL: nil, bottleURL: root,
            source: .pinned, launch: .program(root.appendingPathComponent("game.exe"))
        )
        return (root, entry)
    }

    @Test func samplesKeepLastCompletedSessionStableAndFailedLaunchCreatesNoCompletion() throws {
        let (root, game) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GameActivityStore()
        let ownerID = UUID()
        var owner = try store.acquireOwnership(for: game, source: .gui, ownerID: ownerID)
        _ = try store.recordSample(
            seconds: 10, at: Date(timeIntervalSince1970: 100), for: game,
            ownerID: ownerID, generation: owner.generation, sequence: 1
        )
        #expect(try store.load(for: game).lastSessionEndedAt == nil)
        let end = Date(timeIntervalSince1970: 110)
        #expect(try store.completeSession(for: game, at: end, ownerID: ownerID, generation: owner.generation))
        owner = try store.acquireOwnership(for: game, source: .gui, ownerID: ownerID)
        _ = try store.recordSample(
            seconds: 5, at: Date(timeIntervalSince1970: 200), for: game,
            ownerID: ownerID, generation: owner.generation, sequence: 1
        )
        let activity = try store.load(for: game)
        #expect(activity.lastSessionEndedAt == end)
        #expect(activity.playTime == 15)
        #expect(try store.completeSession(
            for: game, at: Date(), ownerID: ownerID, generation: owner.generation - 1
        ) == false)
        #expect(try store.load(for: game).owner?.generation == owner.generation)
    }

    @Test func observationSurvivesStorageFailureAndRetriesCompletion() async throws {
        let (root, game) = try fixture()
        let bottle = Bottle(bottleUrl: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("Game Activity")
        try Data("blocked".utf8).write(to: blocked)
        let tracker = GameActivityTracker()
        tracker.automaticallyPolls = false
        var date = Date(timeIntervalSince1970: 100)
        var processes = [WineProcess(imageName: "game.exe", winePID: 1, memoryUsage: "0 K", kind: .app)]
        tracker.now = { date }
        tracker.wineserverProbe = { _ in true }
        tracker.processProbe = { _ in processes }
        tracker.track(game, executable: root.appendingPathComponent("game.exe"), bottle: bottle)
        await tracker.poll()
        #expect(tracker.observation.runningEntryIDs == [game.id])
        #expect(tracker.error != nil)
        processes = []
        date = Date(timeIntervalSince1970: 110)
        await tracker.poll()
        #expect(tracker.observation.runningEntryIDs == [game.id])
        date = Date(timeIntervalSince1970: 112)
        await tracker.poll()
        #expect(tracker.observation.endedEntryIDs == [game.id])
        #expect(tracker.observation.completedAt[game.id] == Date(timeIntervalSince1970: 110))
        try FileManager.default.removeItem(at: blocked)
        await tracker.poll()
        let saved = try GameActivityStore.shared.load(for: game)
        #expect(saved.lastSessionEndedAt == Date(timeIntervalSince1970: 110))
        #expect(saved.owner == nil)
    }

    @Test func restartedGameRetriesPriorCompletionAndResumesSampling() async throws {
        let (root, game) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("Game Activity")
        try Data("blocked".utf8).write(to: blocked)
        let tracker = GameActivityTracker()
        tracker.automaticallyPolls = false
        var date = Date(timeIntervalSince1970: 100)
        let process = WineProcess(imageName: "game.exe", winePID: 1, memoryUsage: "0 K", kind: .app)
        var processes = [process]
        tracker.now = { date }
        tracker.wineserverProbe = { _ in true }
        tracker.processProbe = { _ in processes }
        tracker.track(game, executable: root.appendingPathComponent("game.exe"), bottle: Bottle(bottleUrl: root))
        await tracker.poll()
        processes = []
        date = Date(timeIntervalSince1970: 110)
        await tracker.poll()
        await tracker.poll()
        processes = [process]
        date = Date(timeIntervalSince1970: 120)
        await tracker.poll()
        try FileManager.default.removeItem(at: blocked)
        await tracker.poll()
        let saved = try GameActivityStore.shared.load(for: game)
        #expect(saved.lastSessionEndedAt == Date(timeIntervalSince1970: 110))
        #expect(saved.owner != nil)
        #expect(tracker.error == nil)
        #expect(tracker.observation.runningEntryIDs == [game.id])
    }

    @Test func launcherIsObservedAcrossConfigurationWithoutActivityWrites() async throws {
        let (root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("steam.exe")
        let entry = LibraryEntry(
            id: UUID().uuidString, name: "Steam", iconURL: nil, bottleURL: root,
            source: .pinned, launch: .program(executable), launcher: .steam
        )
        let bottle = Bottle(bottleUrl: root)
        let tracker = GameActivityTracker()
        tracker.automaticallyPolls = false
        var processes = [WineProcess(imageName: "steam.exe", winePID: 1, memoryUsage: "0 K", kind: .app)]
        tracker.wineserverProbe = { _ in true }
        tracker.processProbe = { _ in processes }
        tracker.track(entry, executable: executable, bottle: bottle)
        await tracker.configure(entries: [entry], bottle: bottle)
        await tracker.poll()
        #expect(tracker.observation.runningEntryIDs == [entry.id])
        processes = []
        await tracker.poll()
        await tracker.poll()
        #expect(tracker.observation.runningEntryIDs.isEmpty)
        #expect(tracker.observation.endedEntryIDs == [entry.id])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Game Activity").path))
    }

    @Test func transientMissingSnapshotOrQueryFailureKeepsSessionOpen() async throws {
        let (root, game) = try fixture()
        let bottle = Bottle(bottleUrl: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let tracker = GameActivityTracker()
        tracker.automaticallyPolls = false
        let process = WineProcess(imageName: "game.exe", winePID: 1, memoryUsage: "0 K", kind: .app)
        var processes = [process]
        var fails = false
        tracker.wineserverProbe = { _ in true }
        tracker.processProbe = { _ in
            if fails {
                throw WineProcessQuery.Failure.invalidProcessList
            }
            return processes
        }
        tracker.track(game, executable: root.appendingPathComponent("game.exe"), bottle: bottle)
        await tracker.poll()
        processes = []
        await tracker.poll()
        fails = true
        await tracker.poll()
        #expect(tracker.queryFailures[bottle.url] != nil)
        fails = false
        processes = [process]
        await tracker.poll()
        #expect(tracker.observation.runningEntryIDs == [game.id])
        #expect(tracker.observation.completedAt.isEmpty)
        #expect(try GameActivityStore.shared.load(for: game).lastSessionEndedAt == nil)
        #expect(tracker.queryFailures.isEmpty)
    }

    @Test func aLaunchWakesTheSleepingPoller() async throws {
        let start = ContinuousClock.now
        let (root, game) = try fixture()
        let bottle = Bottle(bottleUrl: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let tracker = GameActivityTracker()
        tracker.idlePollInterval = .seconds(60)
        var serverActive = false
        var probes = 0
        tracker.wineserverProbe = { _ in probes += 1
            return serverActive
        }
        tracker.processProbe = { _ in
            [WineProcess(imageName: "game.exe", winePID: 1, memoryUsage: "0 K", kind: .app)]
        }
        await tracker.configure(entries: [game], bottle: bottle)
        for _ in 0 ..< 200 where probes == 0 {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(probes > 0)
        serverActive = true
        tracker.track(game, executable: root.appendingPathComponent("game.exe"), bottle: bottle)
        for _ in 0 ..< 200 where tracker.observation.runningEntryIDs.isEmpty {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(tracker.observation.runningEntryIDs == [game.id])
        await tracker.stopPolling()
        #expect(start.duration(to: .now) < .seconds(2))
    }

    @Test func aLockedActivityFileKeepsProcessObservationResponsive() async throws {
        let (root, game) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Game Activity")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hash = SHA256.hash(data: Data(game.metadataIdentity.utf8)).map { String(format: "%02x", $0) }.joined()
        let descriptor = open(directory.appendingPathComponent(hash + ".lock").path, O_CREAT | O_RDWR, 0o600)
        try #require(descriptor >= 0)
        defer { flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        try #require(flock(descriptor, LOCK_EX) == 0)
        let tracker = GameActivityTracker()
        tracker.automaticallyPolls = false
        var processes = [WineProcess(imageName: "game.exe", winePID: 1, memoryUsage: "0 K", kind: .app)]
        tracker.wineserverProbe = { _ in true }
        tracker.processProbe = { _ in processes }
        tracker.track(game, executable: root.appendingPathComponent("game.exe"), bottle: Bottle(bottleUrl: root))
        let start = ContinuousClock.now
        await tracker.poll(waitForPersistence: false)
        #expect(tracker.observation.runningEntryIDs == [game.id])
        processes = []
        await tracker.poll(waitForPersistence: false)
        await tracker.poll(waitForPersistence: false)
        #expect(tracker.observation.endedEntryIDs == [game.id])
        #expect(start.duration(to: .now) < .seconds(2))
        flock(descriptor, LOCK_UN)
        await tracker.stopPolling()
        #expect(try GameActivityStore.shared.load(for: game).lastSessionEndedAt != nil)
    }
}
