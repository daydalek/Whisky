//
//  LinuxDesktopTests.swift
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

private func desktopLauncher(_ root: URL) throws -> URL {
    let url = root.appendingPathComponent("Launcher = 中文 $HOME %f")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
}

@Test @MainActor func linuxDesktopInstallIsIdempotentAndPreservesMimeDefaults() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let launcher = try desktopLauncher(fixture.root)
    let data = fixture.root.appendingPathComponent("User data")
    let defaults = fixture.root.appendingPathComponent("mimeapps.list")
    let bytes = Data("[Default Applications]\napplication/x-msi=existing.desktop;\n".utf8)
    try bytes.write(to: defaults)
    let service = LinuxDesktopService(environment: ["XDG_DATA_HOME": data.path], searchPaths: [])
    let params: [String: JSONValue] = ["launcher": .string(launcher.path)]
    let before = try await service.call("system.desktop.status", params: params, workspace: fixture.workspace)
    #expect(before.object?["installed"] == .bool(false))
    let result = try await service.call("system.desktop.install", params: params, workspace: fixture.workspace)
    #expect(result.object?["cacheUpdated"] == .bool(false))
    let target = try #require(result.object?["path"]?.string)
    let installed = try Data(contentsOf: URL(fileURLWithPath: target))
    #expect(String(bytes: installed, encoding: .utf8)?.contains(" %f\n") == true)
    let again = try await service.call("system.desktop.install", params: params, workspace: fixture.workspace)
    #expect(again.object?["installed"] == .bool(true))
    #expect(try Data(contentsOf: URL(fileURLWithPath: target)) == installed)
    #expect(try Data(contentsOf: defaults) == bytes)
}

@Test func linuxDesktopPublicationRetainsForeignFilesSymlinksAndStages() throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let target = fixture.root.appendingPathComponent("foreign.desktop")
    let original = Data("foreign application".utf8)
    try original.write(to: target)
    #expect(throws: (any Error).self) { try LinuxDesktopEntry.publish("new application", at: target) }
    #expect(try Data(contentsOf: target) == original)
    let alias = fixture.root.appendingPathComponent("alias.desktop")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
    #expect(throws: (any Error).self) { try LinuxDesktopEntry.publish("foreign application", at: alias) }
    #expect(try Data(contentsOf: target) == original)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        .allSatisfy { !$0.hasPrefix(".whisky-desktop-") })
}

@Test @MainActor func linuxProgramShortcutPreservesSourceAndExplicitContainerIdentity() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let launcher = try desktopLauncher(fixture.root)
    let marker = fixture.source.appendingPathComponent("Metadata.plist")
    let metadata = try Data(contentsOf: marker)
    let registry = try fixture.read(fixture.registry)
    let service = LinuxDesktopService(environment: ["XDG_DATA_HOME": fixture.root.path], searchPaths: [])
    let result = try await service.call("programs.shortcut.create", params: fixture.params.merging([
        "launcher": .string(launcher.path), "executable": .string(fixture.executable.path),
        "destination": .string(service.applications.path), "name": .string("中文 %f Game")
    ]) { _, value in value }, workspace: fixture.workspace)
    let path = try #require(result.object?["path"]?.string)
    #expect(path.hasSuffix("中文 %f Game.desktop"))
    let contents = try String(contentsOfFile: path, encoding: .utf8)
    #expect(contents.contains("\"--container-id\""))
    #expect(contents.contains(LinuxDesktopEntry.argument("drive_c/Game/game.exe")))
    #expect(contents.contains("%%f"))
    #expect(try Data(contentsOf: marker) == metadata)
    #expect(try fixture
        .read(fixture.registry)["paths"] as? [[String: String]] == registry["paths"] as? [[String: String]])
    #expect(try (fixture.read(fixture.registry)[ContainerIdentities.key] as? [String: Any])?.count == 1)
}

@Test @MainActor func linuxDesktopRejectsMissingLaunchersAndUnregisteredProgramTargets() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let launcher = try desktopLauncher(fixture.root)
    let service = LinuxDesktopService(environment: ["XDG_DATA_HOME": fixture.root.path], searchPaths: [])
    await #expect(throws: (any Error).self) {
        try await service.call(
            "system.desktop.install",
            params: ["launcher": .string(fixture.source.path)],
            workspace: fixture.workspace
        )
    }
    await #expect(throws: (any Error).self) {
        try await service.call(
            "programs.shortcut.create",
            params: [
                "launcher": .string(launcher.path),
                "container": .string(fixture.root.path),
                "executable": .string(fixture.executable.path),
                "destination": .string(fixture.root.path)
            ],
            workspace: fixture.workspace
        )
    }
    #expect(!FileManager.default.fileExists(atPath: service.applications.path))
}

@Test func linuxProcessIdentityAcceptsByteTruncatedUTF8Names() {
    let fields = ["S"] + (1 ... 18).map(String.init) + ["987654321", "0"]
    let bytes = Data("123 (Frontend = ".utf8) + Data([0xE6, 0x96]) + Data((") " + fields.joined(separator: " ")).utf8)
    #expect(String(bytes: bytes, encoding: .utf8) == nil)
    #expect(LinuxProcStatParser.startTime(from: bytes) == 987_654_321)
}
