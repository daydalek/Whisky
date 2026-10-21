//
//  TerminalScriptWriterTests.swift
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

@Suite("Portable terminal script handoff")
struct TerminalScriptWriterTests {
    @Test func scriptRetainsCommandAndArgumentsAndHasExecutablePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = #"env WINEPREFIX='/tmp/prefix with spaces' wine64 'game.exe' '--name=a"b'"#
        let first = try TerminalScriptWriter.write(command: command, directory: directory)
        let second = try TerminalScriptWriter.write(command: command, directory: directory)
        #expect(first != second)
        #expect(try String(contentsOf: first, encoding: .utf8) == "#!/bin/bash\n\(command)\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: first.path)
        #expect((attributes[.posixPermissions] as? Int).map { $0 & 0o777 } == 0o755)
    }

    @Test func unavailableDestinationsPropagateFailure() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: (any Error).self) { try TerminalScriptWriter.write(command: "exit 0", directory: missing) }
        let remote = try #require(URL(string: "https://example.invalid/scripts/"))
        #expect(throws: (any Error).self) { try TerminalScriptWriter.write(command: "exit 0", directory: remote) }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }
}
