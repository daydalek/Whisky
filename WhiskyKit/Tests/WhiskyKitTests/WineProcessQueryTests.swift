//
//  WineProcessQueryTests.swift
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

import Darwin
import Foundation
import Testing
@testable import WhiskyKit

struct WineProcessQueryTests {
    @Test func commandCompletesWhileDescendantRetainsOutputHandles() async throws {
        let result = try await WineProcessQuery.run(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "sleep 30 & printf '%s\\n' $!; printf 'registry finished' >&2"],
            environment: [:], timeout: 5
        )
        let child = try #require(Int32(result.output.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(child, SIGTERM) }
        #expect(result.exitCode == 0)
        #expect(result.diagnostics == "registry finished")
        #expect(kill(child, 0) == 0)
    }

    @Test func unicodeSnapshotHelperIsBundled() throws {
        let helper = try #require(Wine.processSnapshotHelperURL)
        let data = try Data(contentsOf: helper)
        #expect(data.starts(with: [0x4D, 0x5A]))
        for api in ["Process32FirstW", "Process32NextW", "WideCharToMultiByte"] {
            #expect(data.range(of: Data(api.utf8)) != nil)
        }
    }

    @Test func csvKeepsQuotedCommasQuotesAndUnicodeImageNames() {
        let csv = "\"確認,game\"\".exe\",\"42\",\"Console\",\"1\",\"1,024 K\"\r\n"
        let processes = Wine.parseTasklistOutput(csv)
        #expect(processes.count == 1)
        #expect(processes.first?.imageName == "確認,game\".exe")
        #expect(processes.first?.winePID == 42)
        #expect(processes.first?.memoryUsage == "1,024 K")
    }

    @Test func wholeOutputIsCollectedAndExitCodeIsPreserved() async throws {
        let result = try await WineProcessQuery.run(
            executable: URL(filePath: "/bin/sh"),
            arguments: ["-c", "printf '確認,game.exe'; printf 'failure' >&2; exit 7"], environment: [:]
        )
        #expect(result.output == "確認,game.exe")
        #expect(result.diagnostics == "failure")
        #expect(result.exitCode == 7)
    }

    @Test func helperQueriesHaveBoundedLifetime() async throws {
        let start = ContinuousClock.now
        await #expect(throws: WineProcessQuery.Failure.self) {
            _ = try await WineProcessQuery.run(
                executable: URL(filePath: "/bin/sleep"), arguments: ["10"], environment: [:], timeout: 0.05
            )
        }
        #expect(start.duration(to: .now) < .seconds(3))
    }

    @Test @MainActor func processQueriesRejectNonzeroAndUnparseableOutput() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("query")
        for script in ["#!/bin/sh\nexit 7\n", "#!/bin/sh\nprintf 'unreadable output'\n"] {
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            await #expect(throws: WineProcessQuery.Failure.self) {
                _ = try await Wine.queryProcesses(executable: executable, environment: [:])
            }
        }
    }
}
