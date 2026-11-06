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
        /// Arguments placed before the shell command for this emulator.
        /// `-e` is the xterm convention; GNOME emulators take `--`; kitty,
        /// foot and WezTerm (`start --`) run the command positionally.
        let argumentPrefix: [String]
        var payload: JSONValue {
            .object(["id": .string(id), "name": .string(name), "path": .string(executable.path)])
        }
    }

    typealias Launcher = @Sendable (URL, [String], [String: String]) throws -> Void
    let searchPaths: [URL]
    let environment: [String: String]
    var launch: Launcher = Self.launchProcess
    static let choices: [(id: String, name: String, prefix: [String])] = [
        ("x-terminal-emulator", "系统终端", ["-e"]),
        ("gnome-terminal", "GNOME Terminal", ["--"]),
        ("kgx", "GNOME Console", ["--"]),
        ("konsole", "Konsole", ["-e"]),
        ("xfce4-terminal", "Xfce Terminal", ["-e"]),
        ("mate-terminal", "MATE Terminal", ["-e"]),
        ("lxterminal", "LXTerminal", ["-e"]),
        ("tilix", "Tilix", ["-e"]),
        ("alacritty", "Alacritty", ["-e"]),
        ("ghostty", "Ghostty", ["-e"]),
        ("kitty", "kitty", []),
        ("wezterm", "WezTerm", ["start", "--"]),
        ("foot", "Foot", []),
        ("xterm", "XTerm", ["-e"]),
        ("urxvt", "rxvt-unicode", ["-e"])
    ]
    /// Emulators that cannot connect to a Wayland-only desktop.
    private static let x11Only: Set<String> = ["xterm", "uxterm", "urxvt"]
    var displayAvailable: Bool {
        ["DISPLAY", "WAYLAND_DISPLAY"].contains { environment[$0]?.isEmpty == false }
    }

    func available() -> [Terminal] {
        let choices = waylandOnly
            ? Self.choices.sorted { Self.waylandRank($0.id) < Self.waylandRank($1.id) }
            : Self.choices
        var terminals: [Terminal] = choices.compactMap { choice in
            guard let executable = searchPaths.map({ $0.appendingPathComponent(choice.id) })
                .first(where: { Self.isExecutable($0) })
            else { return nil }
            let resolved = executable.resolvingSymlinksInPath().lastPathComponent
            if displayAvailable {
                if Self.x11Only.contains(resolved), environment["DISPLAY"]?.isEmpty != false {
                    return nil
                }
                if resolved == "foot", environment["WAYLAND_DISPLAY"]?.isEmpty != false {
                    return nil
                }
            }
            return Terminal(
                id: choice.id,
                name: choice.name,
                executable: executable,
                argumentPrefix: choice.prefix
            )
        }
        if let preferred = preferredTerminal() {
            // $TERMINAL is the explicit user choice; it outranks every
            // discovered emulator without duplicating a listed one.
            let resolved = preferred.executable.resolvingSymlinksInPath()
            terminals.removeAll { $0.executable.resolvingSymlinksInPath() == resolved }
            terminals.insert(preferred, at: 0)
        }
        return terminals
    }

    /// The emulator named by `$TERMINAL` (first word), when it resolves to an
    /// executable on `searchPaths` or an absolute path.
    private func preferredTerminal() -> Terminal? {
        guard let raw = environment["TERMINAL"], !raw.isEmpty,
              let name = raw.split(whereSeparator: \.isWhitespace).first.map(String.init)
        else { return nil }
        let executable: URL? = if name.hasPrefix("/") {
            Self.isExecutable(URL(fileURLWithPath: name)) ? URL(fileURLWithPath: name) : nil
        } else {
            searchPaths.map { $0.appendingPathComponent(name) }.first(where: { Self.isExecutable($0) })
        }
        guard let executable else { return nil }
        let resolved = executable.resolvingSymlinksInPath().lastPathComponent
        let prefix = Self.choices.first { $0.id == resolved }?.prefix ?? ["-e"]
        return Terminal(
            id: "$TERMINAL",
            name: "$TERMINAL (\(resolved))",
            executable: executable,
            argumentPrefix: prefix
        )
    }

    private static func waylandRank(_ id: String) -> Int {
        switch id {
        case "foot": 0
        case "gnome-terminal", "kgx": 1
        default: 2
        }
    }

    private var waylandOnly: Bool {
        environment["WAYLAND_DISPLAY"]?.isEmpty == false && environment["DISPLAY"]?.isEmpty != false
    }

    func describe(preferred: String) -> JSONValue {
        .object([
            "available": .array(available().map(\.payload)),
            "preferred": .string(preferred),
            "displayAvailable": .bool(displayAvailable)
        ])
    }

    func open(
        container: URL,
        preferred: String,
        wineEnvironment: [String: String] = [:]
    ) throws -> JSONValue {
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
        for (key, value) in wineEnvironment {
            environment[key] = value
        }
        environment["WINEPREFIX"] = container.path
        let shell = environment["SHELL"].flatMap { path -> String? in
            path.hasPrefix("/") && Self.isExecutable(URL(fileURLWithPath: path)) ? path : nil
        } ?? "/bin/sh"
        // Positional arguments retain literal prefix/shell paths across terminal server processes.
        let script = "cd -- \"$1\" && export WINEPREFIX=\"$1\" && exec \"$2\" -i"
        let arguments = terminal.argumentPrefix + [
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
