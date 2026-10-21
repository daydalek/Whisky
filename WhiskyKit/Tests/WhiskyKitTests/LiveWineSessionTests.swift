//
//  LiveWineSessionTests.swift
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

struct LiveWineSessionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WHISKY_LIVE_WINE_BINARY"] != nil))
    @MainActor func coldRegistryImportCompletesDuringProcessPolling() async throws {
        let configuration = ProcessInfo.processInfo.environment
        let binary = try URL(filePath: #require(configuration["WHISKY_LIVE_WINE_BINARY"]))
        let prefix = try URL(filePath: #require(configuration["WHISKY_LIVE_WINE_PREFIX"]))
        let bottle = Bottle(bottleUrl: prefix)
        var environment = Wine.constructWineEnvironment(for: bottle, environment: [:])
        environment["WINEDEBUG"] = "-all"
        var successfulSnapshots = 0
        let polling = Task {
            while !Task.isCancelled {
                if (try? await Wine.queryProcesses(executable: binary, environment: environment)) != nil {
                    successfulSnapshots += 1
                }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
        }
        defer { polling.cancel() }
        try await Wine.importRegistry(
            document: "Windows Registry Editor Version 5.00\r\n\r\n"
                + "[HKEY_CURRENT_USER\\Software\\WhiskyColdStartProbe]\r\n\"Probe\"=\"1\"\r\n",
            bottle: bottle
        )
        let result = try await WineProcessQuery.run(
            executable: binary,
            arguments: ["reg", "query", "HKEY_CURRENT_USER\\Software\\WhiskyColdStartProbe", "/v", "Probe"],
            environment: environment
        )
        #expect(result.exitCode == 0, "\(result.diagnostics)")
        #expect(result.output.contains("REG_SZ"))
        #expect(result.output.contains("1"))
        polling.cancel()
        await polling.value
        #expect(successfulSnapshots > 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WHISKY_LIVE_WINE_BINARY"] != nil))
    @MainActor func confirmsAndCompletesAnActualWindowsProcess() async throws {
        let configuration = ProcessInfo.processInfo.environment
        let binary = try URL(filePath: #require(configuration["WHISKY_LIVE_WINE_BINARY"]))
        let prefix = try URL(filePath: #require(configuration["WHISKY_LIVE_WINE_PREFIX"]))
        let executable = try URL(filePath: #require(configuration["WHISKY_LIVE_WINE_EXE"]))
        let environment = ["WINEPREFIX": prefix.path, "WINEDEBUG": "-all", "LC_ALL": "en_US.UTF-8"]
        let entry = LibraryEntry(
            id: "live-wine-" + UUID().uuidString, name: "Controlled Wine probe", iconURL: nil,
            bottleURL: prefix, source: .pinned, launch: .program(executable)
        )
        let previousCompletion = try GameActivityStore.shared.load(for: entry).lastSessionEndedAt
        let process = Process()
        process.executableURL = binary
        process.arguments = [executable.path]
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }
        let tracker = GameActivityTracker()
        tracker.automaticallyPolls = false
        tracker.wineserverProbe = { _ in
            let query = try await WineProcessQuery.run(
                executable: binary.deletingLastPathComponent().appendingPathComponent("wineserver"),
                arguments: ["-k0"], environment: environment, timeout: 3
            )
            return query.exitCode == 0
        }
        tracker.processProbe = { _ in try await Wine.queryProcesses(executable: binary, environment: environment) }
        tracker.track(entry, executable: executable, bottle: Bottle(bottleUrl: prefix))
        for _ in 0 ..< 20 where tracker.observation.runningEntryIDs.isEmpty {
            await tracker.poll()
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(tracker.observation.runningEntryIDs == [entry.id])
        #expect(tracker.queryFailures.isEmpty)
        #expect(try GameActivityStore.shared.load(for: entry).lastSessionEndedAt == previousCompletion)
        process.terminate()
        for _ in 0 ..< 20 where tracker.observation.completedAt[entry.id] == nil {
            await tracker.poll()
            try await Task.sleep(for: .milliseconds(100))
        }
        let end = try #require(tracker.observation.completedAt[entry.id])
        #expect(try GameActivityStore.shared.load(for: entry).lastSessionEndedAt == end)
        #expect(tracker.observation.runningEntryIDs.isEmpty)
    }
}
