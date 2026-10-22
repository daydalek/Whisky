//
//  LinuxTerminalService.swift
//  WhiskyApplication
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
import WhiskyBridgeProtocol

@MainActor
struct LinuxTerminalService {
    struct Terminal: Sendable {
        let id: String
        let name: String
        let executable: URL
        var payload: JSONValue {
            .object(["id": .string(id), "name": .string(name), "path": .string(executable.path)])
        }
    }

    typealias Launcher = @Sendable (URL, [String], [String: String]) throws -> Void
    let searchPaths: [URL]
    let environment: [String: String]
    var launch: Launcher = Self.launchProcess
    static let choices = [("x-terminal-emulator", "系统终端"), ("gnome-terminal", "GNOME Terminal"), ("xterm", "XTerm")]
    var displayAvailable: Bool {
        ["DISPLAY", "WAYLAND_DISPLAY"].contains { environment[$0]?.isEmpty == false }
    }

    func available() -> [Terminal] {
        Self.choices.compactMap { id, name in
            guard let executable = searchPaths.map({ $0.appendingPathComponent(id) })
                .first(where: { Self.isExecutable($0) })
            else { return nil }
            return Terminal(id: id, name: name, executable: executable)
        }
    }

    func describe(preferred: String) -> JSONValue {
        .object([
            "available": .array(available().map(\.payload)),
            "preferred": .string(preferred),
            "displayAvailable": .bool(displayAvailable)
        ])
    }

    func open(container: URL, preferred: String) throws -> JSONValue {
        guard displayAvailable else { throw BridgeFailure(
            "display_unavailable",
            "A desktop display is required to open a terminal"
        ) }
        let terminals = available()
        let terminal = preferred == "auto" ? terminals.first : terminals.first { $0.id == preferred }
        guard let terminal else { throw BridgeFailure(
            "terminal_unavailable",
            "Install or select an available Linux terminal"
        ) }
        var environment = environment
        environment["WINEPREFIX"] = container.path
        let shell = environment["SHELL"].flatMap { path -> String? in
            path.hasPrefix("/") && Self.isExecutable(URL(fileURLWithPath: path)) ? path : nil
        } ?? "/bin/sh"
        // Positional arguments retain literal prefix/shell paths across terminal server processes.
        let script = "cd -- \"$1\" && export WINEPREFIX=\"$1\" && exec \"$2\" -i"
        let arguments = [
            terminal.id == "gnome-terminal" ? "--" : "-e",
            "/bin/sh",
            "-c",
            script,
            "whisky-terminal",
            container.path,
            shell
        ]
        do { try launch(terminal.executable, arguments, environment) } catch {
            throw BridgeFailure("host_failed", error.localizedDescription)
        }
        return .object(["accepted": .bool(true), "terminal": .string(terminal.id)])
    }

    private nonisolated static func isExecutable(_ url: URL) -> Bool {
        let target = url.resolvingSymlinksInPath()
        return (try? target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            && FileManager.default.isExecutableFile(atPath: url.path)
    }

    private nonisolated static func launchProcess(
        _ executable: URL,
        _ arguments: [String],
        _ environment: [String: String]
    ) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in }
        try process.run()
    }
}
