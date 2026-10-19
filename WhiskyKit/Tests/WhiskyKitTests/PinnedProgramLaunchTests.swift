//
//  PinnedProgramLaunchTests.swift
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

@Suite("Pinned program launch settings")
@MainActor
struct PinnedProgramLaunchTests {
    private func makeProgram(extensionName: String, root: URL) throws -> Program {
        try FileManager.default.createDirectory(
            at: root.appending(path: "drive_c/windows/system32"), withIntermediateDirectories: true
        )
        let bottle = Bottle(bottleUrl: root)
        bottle.settings.graphicsBackend = .dxvk
        let url = root.appending(path: "drive_c/Setup.\(extensionName)")
        try Data("pin".utf8).write(to: url)
        let program = Program(url: url, bottle: bottle)
        program.settings.arguments = "first second"
        program.settings.environment = ["PIN_ENVIRONMENT": "preserved"]
        program.settings.activeWineDebugPreset = .dllLoad
        var overrides = ProgramOverrides()
        overrides.dllOverrides = [DLLOverrideEntry(dllName: "d2d1", mode: .disabled)]
        program.settings.overrides = overrides
        return program
    }

    @Test(arguments: ["bat", "msi", "msix", "appx", "url"])
    func pinnedFilesKeepProgramLaunchSettings(_ extensionName: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let program = try makeProgram(extensionName: extensionName, root: root)
        var writes: [(scope: Wine.DLLOverrideScope, overrides: String)] = []

        let launch = try await program.prepareLaunch(overrideWriter: { _, scopes in writes = scopes })

        #expect(launch.arguments == ["start", "/unix", program.url.path(percentEncoded: false), "first", "second"])
        #expect(launch.environment["PIN_ENVIRONMENT"] == "preserved")
        #expect(launch.environment["WINEDEBUG"] == WineDebugPreset.dllLoad.winedebugValue)
        let programScope = try #require(writes.first { $0.scope == .program(program.url.lastPathComponent) })
        #expect(Wine.parseDLLOverrides(programScope.overrides)["d2d1"] == "")
    }

    @Test
    func batchPinsKeepTerminalLaunchSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let program = try makeProgram(extensionName: "bat", root: root)
        var writes: [(scope: Wine.DLLOverrideScope, overrides: String)] = []

        let script = try await program.writeTerminalScript(
            args: ["first", "second"], overrideWriter: { _, scopes in writes = scopes }
        )
        defer { try? FileManager.default.removeItem(at: script) }

        let contents = try String(contentsOf: script, encoding: .utf8)
        #expect(contents.contains("PIN_ENVIRONMENT=preserved"))
        #expect(contents.contains("start /unix \(program.url.esc) first second"))
        let programScope = try #require(writes.first { $0.scope == .program("Setup.bat") })
        #expect(Wine.parseDLLOverrides(programScope.overrides)["d2d1"] == "")
    }
}
