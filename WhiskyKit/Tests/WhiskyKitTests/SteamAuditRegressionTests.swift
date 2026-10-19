//
//  SteamAuditRegressionTests.swift
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

@Suite("Steam audit regressions")
@MainActor
struct SteamAuditRegressionTests {
    private func pendingRequest() -> Task<Wine.ProgramRunResult, any Error> {
        Task {
            try await Task.sleep(for: .seconds(30))
            return Wine.ProgramRunResult(
                exitCode: 0,
                logFileURL: URL(filePath: "/tmp/steam.log"),
                runLogEntryId: UUID()
            )
        }
    }

    @Test func pendingRequestKeepsPollingAndHonorsTimeout() async throws {
        let request = pendingRequest()
        defer { request.cancel() }
        let start = ContinuousClock.now
        var polls = 0
        let appeared = try await SteamGameLaunchMonitor.wait(
            names: ["game.exe"], timeout: 0.1, pollInterval: .milliseconds(10),
            runningImages: { polls += 1
                return []
            }, accepted: { true },
            prepareRetry: {}, retry: {}, launchTask: request
        )
        #expect(!appeared)
        #expect(polls >= 1)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func pendingRequestAllowsGameAppearance() async throws {
        let request = pendingRequest()
        defer { request.cancel() }
        var polls = 0
        let appeared = try await SteamGameLaunchMonitor.wait(
            names: ["game.exe"], timeout: 10, pollInterval: .milliseconds(10),
            runningImages: { polls += 1
                return polls > 1 ? ["game.exe"] : []
            }, accepted: { true },
            prepareRetry: {}, retry: {}, launchTask: request
        )
        #expect(appeared)
    }

    @Test func pendingRequestDoesNotDelayCancellation() async throws {
        let request = pendingRequest()
        defer { request.cancel() }
        let start = ContinuousClock.now
        let monitor = Task {
            try await SteamGameLaunchMonitor.wait(
                names: ["game.exe"], pollInterval: .seconds(10),
                runningImages: { [] }, accepted: { true }, prepareRetry: {}, retry: {}, launchTask: request
            )
        }
        try await Task.sleep(for: .milliseconds(30))
        monitor.cancel()
        await #expect(throws: CancellationError.self) { _ = try await monitor.value }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func failedRetryRequestIsObserved() async throws {
        await #expect(throws: SteamOrchestratorError.launchRequestFailed(code: 42)) {
            _ = try await SteamGameLaunchMonitor.wait(
                names: ["game.exe"], timeout: 10, retryDelay: 0, pollInterval: .milliseconds(10),
                runningImages: { [] }, accepted: { false }, prepareRetry: {}, retry: {},
                retryLaunch: {
                    Task { Wine.ProgramRunResult(
                        exitCode: 42,
                        logFileURL: URL(filePath: "/tmp/retry.log"),
                        runLogEntryId: UUID()
                    ) }
                }
            )
        }
    }

    @Test func selectedExecutableChangesRefreshRunningStateAndStop() async throws {
        let (bottle, games) = try SteamOrchestratorFixture.makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle.url) }
        let game = games[0]
        let deep = game.installURL.appending(path: "Binaries/Win64/Shipping.exe")
        try FileManager.default.createDirectory(at: deep.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: deep)
        let driver = FakeSteamClientDriver(script: [["steam.exe", "shipping.exe"]])
        let orchestrator = SteamClientOrchestrator(
            bottle: bottle,
            driver: driver,
            timing: SteamOrchestratorFixture.patient
        )
        defer { orchestrator.stop() }
        orchestrator.startTracking(games: games)
        #expect(!orchestrator.runningAppIds.contains(game.appId))
        try SteamGameProgram.select(deep, appID: game.appId, installURL: game.installURL, bottleURL: bottle.url)
        await SteamOrchestratorFixture.eventually("New selection must update tracking") {
            orchestrator.runningAppIds.contains(game.appId)
        }
        await orchestrator.stop(game)
        #expect(driver.killed.contains(101))
        try SteamGameProgram.clear(appID: game.appId, bottleURL: bottle.url)
        await SteamOrchestratorFixture.eventually("Clearing selection must refresh tracking") {
            !orchestrator.runningAppIds.contains(game.appId)
        }
    }
}
