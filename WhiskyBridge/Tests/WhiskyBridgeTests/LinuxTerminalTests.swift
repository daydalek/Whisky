//
//  LinuxTerminalTests.swift
//  WhiskyBridge
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
@testable import WhiskyApplication
import WhiskyBridgeProtocol

private func terminalExecutable(_ url: URL) throws {
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

@Test @MainActor func linuxTerminalDiscoveryKeepsPreferenceAndRejectsDirectories() throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let executable = fixture.root.appendingPathComponent("xterm")
    try terminalExecutable(executable)
    try FileManager.default.createDirectory(
        at: fixture.root.appendingPathComponent("gnome-terminal"),
        withIntermediateDirectories: false
    )
    let service = LinuxTerminalService(searchPaths: [fixture.root], environment: [:])
    let value = service.describe(preferred: "gnome-terminal").object
    #expect(value?["preferred"] == .string("gnome-terminal"))
    #expect(value?["displayAvailable"] == .bool(false))
    #expect(service.available().map(\.id) == ["xterm"])
    #expect(throws: (any Error).self) { try service.open(container: fixture.source, preferred: "auto") }
}

@Test @MainActor func linuxTerminalArgumentsPreserveLiteralPrefixAndShellPaths() throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let prefix = fixture.root.appendingPathComponent("中文 $HOME 'literal' $(touch sentinel)")
    try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: false)
    for id in ["x-terminal-emulator", "gnome-terminal", "xterm"] {
        try terminalExecutable(fixture.root.appendingPathComponent(id))
    }
    let environment = ["DISPLAY": ":123", "SHELL": "/bin/sh", "RETAIN_ENV": "literal $HOME"]
    for id in ["auto", "gnome-terminal", "xterm"] {
        let expected = id == "auto" ? "x-terminal-emulator" : id
        let service = LinuxTerminalService(
            searchPaths: [fixture.root],
            environment: environment
        ) { executable, args, env in
            #expect(executable.lastPathComponent == expected)
            #expect(args.first == (expected == "gnome-terminal" ? "--" : "-e"))
            #expect(args[1] == "/bin/sh" && args[2] == "-c")
            #expect(args[5] == prefix.path && args[6] == "/bin/sh")
            #expect(!args[3].contains(prefix.path))
            #expect(env["WINEPREFIX"] == prefix.path)
            #expect(env["RETAIN_ENV"] == "literal $HOME")
        }
        #expect(try service.open(container: prefix, preferred: id).object?["terminal"] == .string(expected))
    }
}

@Test @MainActor func linuxTerminalMissingPreferenceAndLaunchFailureStayVisible() throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    try terminalExecutable(fixture.root.appendingPathComponent("xterm"))
    try terminalExecutable(fixture.root.appendingPathComponent("foot"))
    let service = LinuxTerminalService(
        searchPaths: [fixture.root],
        environment: ["WAYLAND_DISPLAY": "wayland-0"]
    ) { _, _, _ in
        throw BridgeFailure("fixture_failure", "Launcher failed")
    }
    #expect(throws: (any Error).self) { try service.open(container: fixture.source, preferred: "gnome-terminal") }
    #expect(throws: (any Error).self) { try service.open(container: fixture.source, preferred: "auto") }
}

@Test @MainActor func linuxTerminalPreferencePersistsIndependentlyOfMacOSTerminal() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let location = fixture.root.appendingPathComponent("preferences.plist")
    let prefs = PreferencesService(fileURL: location, defaultBottleDirectory: fixture.root)
    _ = try prefs.call("preferences.set", params: ["key": .string("preferredLinuxTerminal"), "value": .string("xterm")])
    let reloaded = PreferencesService(fileURL: location, defaultBottleDirectory: fixture.root)
    let values = try reloaded.call("preferences.read", params: [:]).object
    #expect(values?["preferredLinuxTerminal"] == .string("xterm"))
    #expect(values?["preferredTerminal"] == .string("terminal"))
    let native = LinuxApplicationServices(searchPaths: [], preferences: reloaded)
    let status = try await native.call("system.terminals", params: [:], workspace: fixture.workspace).object
    #expect(status?["preferred"] == .string("xterm"))
    await #expect(throws: (any Error).self) {
        try await native.call(
            "bottle.tools",
            params: fixture.params.merging(["tool": .string("regedit")]) { _, new in new },
            workspace: fixture.workspace
        )
    }
}

@Test @MainActor func linuxTerminalsRespectPureWaylandAndX11Protocols() throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    for name in ["foot", "xterm"] {
        try terminalExecutable(fixture.root.appendingPathComponent(name))
    }
    try FileManager.default.createSymbolicLink(
        at: fixture.root.appendingPathComponent("x-terminal-emulator"),
        withDestinationURL: fixture.root.appendingPathComponent("xterm")
    )
    let wayland = LinuxTerminalService(
        searchPaths: [fixture.root], environment: ["WAYLAND_DISPLAY": "wayland-1"]
    ) { executable, args, _ in
        #expect(executable.lastPathComponent == "foot" && args.first == "-e")
        #expect(args[5] == fixture.source.path)
    }
    #expect(wayland.available().map(\.id) == ["foot"])
    #expect(try wayland.open(container: fixture.source, preferred: "auto").object?["terminal"] == .string("foot"))
    #expect(throws: (any Error).self) { try wayland.open(container: fixture.source, preferred: "xterm") }
    let x11 = LinuxTerminalService(searchPaths: [fixture.root], environment: ["DISPLAY": ":123"])
    #expect(x11.available().map(\.id) == ["x-terminal-emulator", "xterm"])
}
