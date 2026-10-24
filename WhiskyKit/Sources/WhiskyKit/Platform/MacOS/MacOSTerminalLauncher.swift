//
//  MacOSTerminalLauncher.swift
//  WhiskyKit
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

import AppKit
import os.log
import WhiskyCore

@MainActor
public struct MacOSTerminalLauncher: TerminalLaunching {
    public static let shared = MacOSTerminalLauncher()
    private let terminal: @MainActor () -> TerminalApp
    private let execute: @MainActor (String) throws -> Void

    public init(
        terminal: @escaping @MainActor () -> TerminalApp = { .preferred },
        executeScript: (@MainActor (String) throws -> Void)? = nil
    ) {
        self.terminal = terminal
        self.execute = executeScript ?? Self.executeAppleScript
    }

    public func openScript(at url: URL) async throws {
        guard url.isFileURL else { throw TerminalLaunchError(message: "Expected a local terminal script") }
        try execute(terminal().generateAppleScript(for: url.path))
    }

    private static func executeAppleScript(_ source: String) throws {
        guard let script = NSAppleScript(source: source) else {
            throw TerminalLaunchError(message: String(
                localized: "program.terminal.error.scriptInvalid",
                defaultValue: "The command to open the terminal couldn't be prepared."
            ))
        }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            Logger.wineKit.error("Failed to run terminal script \(error)")
            throw TerminalLaunchError(message: error["NSAppleScriptErrorMessage"] as? String ??
                String(describing: error))
        }
    }
}
