//
//  SteamReadyLaunchTests.swift
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

@Suite("Steam ready launch sequencing")
@MainActor
struct SteamReadyLaunchTests {
    @Test func backgroundWineServicesDoNotTriggerTasklist() async throws {
        let (bottle, _) = try SteamOrchestratorFixture.makeBottle()
        let driver = FakeSteamClientDriver(script: [["services.exe", "winedevice.exe"]])
        let model = SteamClientOrchestrator(bottle: bottle, driver: driver)
        #expect(await model.runningImageNames().isEmpty)
        #expect(driver.listCalls == 0)
    }

    @Test func trackingDoesNotRunTasklistDuringClientReadiness() async throws {
        let (bottle, games) = try SteamOrchestratorFixture.makeBottle()
        let driver = FakeSteamClientDriver(script: [["steam.exe"]])
        driver.readinessState = .waitingForLogin
        var timing = SteamOrchestratorFixture.patient
        timing.trackingInterval = .milliseconds(5)
        let model = SteamClientOrchestrator(bottle: bottle, driver: driver, timing: timing)
        model.launch(games[0])
        await SteamOrchestratorFixture.eventually("Waiting for readiness") {
            model.phases[games[0].appId] == .waitingForClient
        }
        let calls = driver.listCalls
        model.startTracking(games: games)
        try await Task.sleep(for: .milliseconds(30))
        #expect(driver.listCalls == calls)
        model.stop()
    }

    @Test func defaultClientStartupBudgetIs150Seconds() {
        #expect(SteamClientOrchestrator.Timing().clientReadyTimeout == 150)
    }

    @Test(arguments: [true, false]) func clientDoesNotLaunchBeforeLogin(cold: Bool) async throws {
        let (bottle, games) = try SteamOrchestratorFixture.makeBottle()
        let driver = FakeSteamClientDriver(script: cold ? [[]] : [["steam.exe"]])
        driver.onStartClient = { driver.script = [["steam.exe"]] }
        driver.readinessState = .waitingForLogin
        let model = SteamClientOrchestrator(bottle: bottle, driver: driver, timing: SteamOrchestratorFixture.patient)
        driver.onLaunchGame = { _ in driver.script = [["steam.exe", "game1.exe"]] }
        model.launch(games[0])
        await SteamOrchestratorFixture.eventually("Waiting for login") {
            model.phases[games[0].appId] == .waitingForClient
        }
        #expect(driver.launched.isEmpty)
        driver.readinessState = .ready
        await SteamOrchestratorFixture.awaitIdle(model)
        #expect(driver.launched == [games[0].appId])
        #expect(model.runningAppIds.contains(games[0].appId))
    }

    @Test func cancellingOneRequestDoesNotCancelAnotherGamesStartup() async throws {
        let (bottle, games) = try SteamOrchestratorFixture.makeBottle(games: [1_086_940, 1_245_620])
        let driver = FakeSteamClientDriver(script: [["steam.exe"]])
        driver.readinessState = .waitingForLogin
        let model = SteamClientOrchestrator(bottle: bottle, driver: driver, timing: SteamOrchestratorFixture.patient)
        driver.onLaunchGame = { _ in driver.script = [["steam.exe", "game2.exe"]] }
        model.launch(games[0])
        model.launch(games[1])
        await SteamOrchestratorFixture.eventually("Both requests waiting") {
            model.phases.values.filter { $0 == .waitingForClient }.count == 2
        }
        model.cancelLaunch(appID: games[0].appId)
        driver.readinessState = .ready
        await SteamOrchestratorFixture.awaitIdle(model)
        #expect(driver.launched == [games[1].appId])
        #expect(driver.killed.isEmpty)
        #expect(model.launchError == nil)
    }

    @Test func cancellingLoginWaitDoesNotLaunchOrKillAnything() async throws {
        let (bottle, games) = try SteamOrchestratorFixture.makeBottle()
        let driver = FakeSteamClientDriver(script: [["steam.exe"]])
        driver.readinessState = .waitingForLogin
        let model = SteamClientOrchestrator(bottle: bottle, driver: driver, timing: SteamOrchestratorFixture.patient)
        model.launch(games[0])
        await SteamOrchestratorFixture.eventually("Waiting for login") {
            model.phases[games[0].appId] == .waitingForClient
        }
        model.cancelLaunch(appID: games[0].appId)
        driver.readinessState = .ready
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.phases.isEmpty)
        #expect(driver.launched.isEmpty)
        #expect(driver.killed.isEmpty)
        #expect(model.launchError == nil)
    }

    @Test func lostUnacknowledgedRequestGetsOnlyOneRetry() async throws {
        let (bottle, games) = try SteamOrchestratorFixture.makeBottle()
        let driver = FakeSteamClientDriver(script: [["steam.exe"]])
        driver.accepted = false
        var timing = SteamOrchestratorFixture.fast
        timing.retryDelay = 0.02
        let model = SteamClientOrchestrator(bottle: bottle, driver: driver, timing: timing)
        model.launch(games[0])
        await SteamOrchestratorFixture.awaitIdle(model)
        #expect(driver.launched.count == 2)
    }

    @Test func acknowledgedCloudOrStatsSyncIsNeverRetried() async throws {
        let (bottle, games) = try SteamOrchestratorFixture.makeBottle()
        let driver = FakeSteamClientDriver(script: [["steam.exe"]])
        driver.accepted = true
        var timing = SteamOrchestratorFixture.fast
        timing.retryDelay = 0.02
        let model = SteamClientOrchestrator(bottle: bottle, driver: driver, timing: timing)
        model.launch(games[0])
        await SteamOrchestratorFixture.awaitIdle(model)
        #expect(driver.launched.count == 1)
    }
}
