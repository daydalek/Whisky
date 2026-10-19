//
//  SteamStartupCancellationTests.swift
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

@Suite("Steam startup preparation cancellation")
@MainActor
struct SteamStartupCancellationTests {
    enum Stage: Sendable { case prefix, gpu }

    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        var entered = false

        func wait() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered = true
            }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    private func makeBottle() throws -> Bottle {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bottle = Bottle(bottleUrl: root, inFlight: false, isAvailable: true)
        bottle.settings.launcherCompatibilityMode = true
        bottle.settings.gpuSpoofing = true
        return bottle
    }

    @Test(arguments: [Stage.prefix, .gpu])
    func driverCancellationPreventsDelayedClientLaunch(stage: Stage) async throws {
        let bottle = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle.url) }
        let gate = Gate()
        var runs = 0
        var preparation: Task<Void, Never>?
        let driver = WineSteamClientDriver(bottle: bottle, clientStarter: { url, bottle, onHandoff in
            let task = SteamLauncher.startClient(
                steamExe: url, bottle: bottle,
                preparePrefix: { _ in if stage == .prefix { await gate.wait() } },
                gpuImporter: { _, _ in if stage == .gpu { await gate.wait() } },
                run: { _, _, _, onHandoff in runs += 1
                    onHandoff()
                }, onHandoff: onHandoff
            )
            preparation = task
            return task
        })
        driver.startClient(steamExe: bottle.url.appending(path: "steam.exe"))
        await SteamOrchestratorFixture.eventually("Preparation must reach the delayed stage") { gate.entered }
        driver.cancelClientStartup()
        gate.release()
        await preparation?.value
        #expect(runs == 0)
    }

    @Test func driverCancellationPreservesClientAfterHandoff() async throws {
        let bottle = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle.url) }
        let running = Gate()
        var cancelled = false
        var preparation: Task<Void, Never>?
        let driver = WineSteamClientDriver(bottle: bottle, clientStarter: { url, bottle, onHandoff in
            let task = SteamLauncher.startClient(
                steamExe: url, bottle: bottle, preparePrefix: { _ in }, gpuImporter: { _, _ in },
                run: { _, _, _, onHandoff in
                    onHandoff()
                    await running.wait()
                    cancelled = Task.isCancelled
                }, onHandoff: onHandoff
            )
            preparation = task
            return task
        })
        driver.startClient(steamExe: bottle.url.appending(path: "steam.exe"))
        await SteamOrchestratorFixture.eventually("Client must receive handoff") { running.entered }
        driver.cancelClientStartup()
        driver.shutdown()
        running.release()
        await preparation?.value
        #expect(!cancelled)
    }

    @Test(arguments: [Stage.prefix, .gpu])
    func directClientWaitCancellationReleasesPreparation(stage: Stage) async throws {
        let bottle = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle.url) }
        let startup = SteamClientStartup()
        let gate = Gate()
        var runs = 0
        var preparation: Task<Void, Never>?
        let waiting = Task {
            await SteamLauncher.startClientIfNeeded(
                isRunning: { false },
                start: {
                    startup.start { onHandoff in
                        let task = SteamLauncher.startClient(
                            steamExe: bottle.url.appending(path: "steam.exe"), bottle: bottle,
                            preparePrefix: { _ in if stage == .prefix { await gate.wait() } },
                            gpuImporter: { _, _ in if stage == .gpu { await gate.wait() } },
                            run: { _, _, _, onHandoff in runs += 1
                                onHandoff()
                            }, onHandoff: onHandoff
                        )
                        preparation = task
                        return task
                    }
                },
                hasStarted: { false }, pollInterval: .milliseconds(5), startup: startup
            )
        }
        await SteamOrchestratorFixture.eventually("Direct launch must reach preparation") { gate.entered }
        waiting.cancel()
        #expect(await waiting.value == false)
        gate.release()
        await preparation?.value
        #expect(runs == 0)
    }

    @Test func lastRequestCancellationAndStopCancelDriverPreparation() async throws {
        let (bottle, games) = try SteamOrchestratorFixture.makeBottle(games: [100, 200])
        defer { try? FileManager.default.removeItem(at: bottle.url) }
        let driver = FakeSteamClientDriver(script: [[]])
        let model = SteamClientOrchestrator(bottle: bottle, driver: driver, timing: SteamOrchestratorFixture.patient)
        model.launch(games[0])
        model.launch(games[1])
        await SteamOrchestratorFixture.eventually("Shared startup must begin") { driver.startClientCalls == 1 }
        model.cancelLaunch(appID: games[0].appId)
        #expect(driver.cancelClientStartupCalls == 0)
        model.cancelLaunch(appID: games[1].appId)
        #expect(driver.cancelClientStartupCalls >= 1)
        let cancellations = driver.cancelClientStartupCalls
        model.stop()
        #expect(driver.cancelClientStartupCalls > cancellations)
    }

    @Test func clientStartupTimeoutCancelsDriverPreparation() async throws {
        let (bottle, games) = try SteamOrchestratorFixture.makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle.url) }
        let driver = FakeSteamClientDriver(script: [[]])
        let model = SteamClientOrchestrator(bottle: bottle, driver: driver, timing: SteamOrchestratorFixture.fast)
        defer { model.stop() }
        model.launch(games[0])
        await SteamOrchestratorFixture.awaitIdle(model)
        #expect(driver.startClientCalls == 1)
        #expect(driver.cancelClientStartupCalls >= 1)
    }
}
