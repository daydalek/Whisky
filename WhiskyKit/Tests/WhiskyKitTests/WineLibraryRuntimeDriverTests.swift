//
//  WineLibraryRuntimeDriverTests.swift
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
import WhiskyCore
@testable import WhiskyKit

@Suite("Wine library runtime adapter")
@MainActor
struct WineLibraryRuntimeDriverTests {
    @Test func programRequestsReuseSettingsAndPublishActualProcessObservations() async throws {
        let (bottle, _) = try SteamOrchestratorFixture.makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle.url) }
        let executable = bottle.url.appendingPathComponent("game.exe")
        try Data().write(to: executable)
        let program = Program(url: executable, bottle: bottle)
        program.settings.arguments = "--saved-setting"
        bottle.programs = [program]
        let entry = LibraryEntry(
            id: "game",
            name: "Game",
            iconURL: nil,
            bottleURL: bottle.url,
            source: .pinned,
            launch: .program(executable)
        )
        let tracker = GameActivityTracker()
        tracker.automaticallyPolls = false
        tracker.wineserverProbe = { _ in true }
        tracker.processProbe = { _ in [WineProcess(imageName: "game.exe", winePID: 1, memoryUsage: "0", kind: .app)] }
        let driver = WineLibraryRuntimeDriver(bottleResolver: { $0 == bottle.url ? bottle : nil }, tracker: tracker)
        var called = false
        driver.programRunner = { chosen, terminal, started in
            #expect(chosen === program)
            #expect(chosen.settings.arguments == "--saved-setting")
            #expect(terminal)
            called = true
            started()
            return .launchedInTerminal(programName: chosen.name)
        }
        let runtime = LibraryRuntimeController(driver: driver)
        runtime.launch(LibraryLaunchRequest(entry: entry, mode: .terminal))
        await SteamOrchestratorFixture.eventually("program adapter should run") { called }
        #expect(runtime.state.launch.state(for: entry) == .launching)
        await tracker.poll()
        await SteamOrchestratorFixture.eventually("process observation should cross the async event boundary") {
            runtime.state.launch.state(for: entry) == .running
        }
        #expect(runtime.state.observation.runningEntryIDs == [entry.id])
        runtime.stopTracking()
    }

    @Test func steamCommandsAndFactoryHooksUseTheSameRuntimeBoundary() async throws {
        let (bottle, games) = try SteamOrchestratorFixture.makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle.url) }
        let game = try #require(games.first)
        let entry = LibraryEntry(
            id: "steam",
            name: game.name,
            iconURL: nil,
            bottleURL: bottle.url,
            source: .steam,
            launch: .steam(appID: game.appId)
        )
        let tracker = GameActivityTracker()
        tracker.automaticallyPolls = false
        let steam = FakeSteamClientDriver(script: [["steam.exe"]])
        steam.onLaunchGame = { _ in steam.script = [["steam.exe", "game1.exe"]] }
        var factoryCalls = 0
        let driver = WineLibraryRuntimeDriver(bottleResolver: { $0 == bottle.url ? bottle : nil }, driverFactory: { _ in
            factoryCalls += 1
            return steam
        }, tracker: tracker)
        driver.steamTiming = SteamOrchestratorFixture.patient
        let runtime = LibraryRuntimeController(driver: driver)
        await runtime.configure(entries: [entry], containerURL: bottle.url)
        runtime.launch(LibraryLaunchRequest(entry: entry))
        await SteamOrchestratorFixture.eventually("Steam launch should reach the injected driver") {
            steam.launched == [game.appId]
        }
        await SteamOrchestratorFixture.eventually("Steam process state should reach the frontend") {
            runtime.state.launch.state(for: entry) == .running
        }
        #expect(factoryCalls == 1)
        #expect(runtime.capabilities(for: entry).contains(.stop))
        await runtime.stop(entry)
        #expect(steam.killed.contains(101))
        runtime.retainContainers([])
        await SteamOrchestratorFixture.eventually("removed containers should release Steam UI state") {
            runtime.state.launch.state(for: entry) == .idle
        }
        #expect(steam.shutdownCalls > 0)
        runtime.stopTracking()
    }

    @Test func folderLaunchWithoutARecordedExecutableFailsAndUnknownContainersExposeNoCapabilities() async throws {
        let (bottle, _) = try SteamOrchestratorFixture.makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle.url) }
        let folder = bottle.url.appendingPathComponent("Folder")
        let entry = LibraryEntry(
            id: "folder",
            name: "Folder",
            iconURL: nil,
            bottleURL: bottle.url,
            source: .folder,
            launch: .program(folder)
        )
        let tracker = GameActivityTracker()
        tracker.automaticallyPolls = false
        let driver = WineLibraryRuntimeDriver(bottleResolver: { $0 == bottle.url ? bottle : nil }, tracker: tracker)
        var calls = 0
        driver.programRunner = { _, _, _ in calls += 1
            return .launchedSuccessfully(programName: "Folder")
        }
        let result = await driver.launchProgram(LibraryLaunchRequest(entry: entry), onStarted: {})
        #expect(result.errorDescription != nil)
        #expect(calls == 0)
        let unknown = LibraryEntry(
            id: "other",
            name: "Other",
            iconURL: nil,
            bottleURL: bottle.url.appendingPathComponent("missing"),
            source: .pinned,
            launch: .program(folder)
        )
        #expect(driver.capabilities(for: unknown).isEmpty)
        driver.stopTracking()
    }

    /// A folder entry names its folder, so the launch reads the executable the
    /// user picked out of the folder library instead of failing.
    @Test func folderLaunchRunsTheExecutableRecordedForIt() async throws {
        let (bottle, _) = try SteamOrchestratorFixture.makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle.url) }
        let folder = bottle.url.appendingPathComponent("Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let executable = folder.appendingPathComponent("game.exe")
        try Data().write(to: executable)
        let folderKey = FolderGameLibrary.key(for: folder, bottleURL: bottle.url)
        var library = FolderGameLibrary()
        library.roots = [folderKey]
        library.executables[folderKey] = FolderGameLibrary.key(for: executable, bottleURL: bottle.url)
        try library.save(bottleURL: bottle.url)

        let entry = LibraryEntry(
            id: "folder",
            name: "Folder",
            iconURL: nil,
            bottleURL: bottle.url,
            source: .folder,
            launch: .program(folder)
        )
        let tracker = GameActivityTracker()
        tracker.automaticallyPolls = false
        let driver = WineLibraryRuntimeDriver(bottleResolver: { $0 == bottle.url ? bottle : nil }, tracker: tracker)
        var launched: URL?
        driver.programRunner = { program, _, _ in
            launched = program.url
            return .launchedSuccessfully(programName: program.name)
        }
        let result = await driver.launchProgram(LibraryLaunchRequest(entry: entry), onStarted: {})
        #expect(result.errorDescription == nil)
        #expect(launched == executable)

        // A recorded executable that has since been deleted is not a target.
        try FileManager.default.removeItem(at: executable)
        let stale = await driver.launchProgram(LibraryLaunchRequest(entry: entry), onStarted: {})
        #expect(stale.errorDescription != nil)
        driver.stopTracking()
    }
}
