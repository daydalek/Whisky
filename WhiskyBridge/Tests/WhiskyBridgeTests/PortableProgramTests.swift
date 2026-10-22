//
//  PortableProgramTests.swift
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
import WhiskyApplication
import WhiskyBridgeProtocol
import WhiskyCore

private struct ProgramFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("portable-program-\(UUID())")
    var container: URL {
        root.appendingPathComponent("Bottle")
    }

    var executable: URL {
        container.appendingPathComponent("drive_c/游戏/game.exe")
    }

    var workspace: ApplicationWorkspace {
        ApplicationWorkspace(containers: [container])
    }

    var locations: (identity: URL, legacy: URL) {
        ProgramStorageLayout.locations(
            for: executable,
            containerURL: container
        )
    }

    var params: [String: JSONValue] {
        ["container": .string(container.path), "executable": .string(executable.path)]
    }

    init() throws {
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x4D, 0x5A]).write(to: executable)
        try write(
            ["info": ["name": "Fixture"], "dxvkConfig": ["dxvk": true]],
            to: container.appendingPathComponent("Metadata.plist")
        )
    }

    func write(_ raw: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: raw, format: .xml, options: 0).write(to: url)
    }

    func read(_ url: URL) throws -> [String: Any] {
        try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Test @MainActor func portableProgramSettingsMigrateAndPatchTheLatestNativeDocument() async throws {
    let fixture = try ProgramFixture()
    defer { fixture.remove() }
    try fixture.write([
        "arguments": "legacy", "environment": ["CUSTOM": "retained"], "future": ["keep": 42],
        "overrides": ["dxvkHud": ["fps": [:]], "futureOverride": "retained"]
    ], to: fixture.locations.legacy)
    let service = ApplicationService(workspace: fixture.workspace)
    let before = try await service.call("programs.settings.read", params: fixture.params)
    #expect(before.object?["defaults"]?.object?["graphicsBackend"] == .string("dxvk"))
    #expect(before.object?["overrides"]?.object?["dxvkHud"] == .string("fps"))
    #expect(!FileManager.default.fileExists(atPath: fixture.locations.identity.path))
    var params = fixture.params
    params["patch"] = .object([
        "locale": .string("ja_JP.UTF-8"), "arguments": .string("--中文 $HOME"),
        "overrides": .object(["enhancedSync": .string("esync"), "dxvkHud": .null])
    ])
    let saved = try await service.call("programs.settings.set", params: params)
    #expect(saved.object?["environment"]?.object?["LANG"] == .string("ja_JP.UTF-8"))
    #expect(saved.object?["environment"]?.object?["CUSTOM"] == .string("retained"))
    var raw = try fixture.read(fixture.locations.identity)
    #expect((raw["future"] as? [String: Int])?["keep"] == 42)
    #expect((raw["overrides"] as? [String: Any])?["futureOverride"] as? String == "retained")
    #expect((raw["overrides"] as? [String: Any])?["dxvkHud"] == nil)
    #expect(((raw["overrides"] as? [String: Any])?["enhancedSync"] as? [String: Any])?["esync"] != nil)
    raw["externalWriter"] = "latest"
    try fixture.write(raw, to: fixture.locations.identity)
    params["patch"] = .object(["locale": .string(""), "overrides": .null])
    _ = try await service.call("programs.settings.set", params: params)
    raw = try fixture.read(fixture.locations.identity)
    #expect(raw["externalWriter"] as? String == "latest")
    #expect(raw["overrides"] == nil)
    #expect((raw["environment"] as? [String: String])?["LANG"] == nil)
}

@Test @MainActor func portableProgramSettingsRejectInvalidPatchesAtomically() async throws {
    let fixture = try ProgramFixture()
    defer { fixture.remove() }
    try fixture.write(["arguments": "original"], to: fixture.locations.identity)
    let before = try Data(contentsOf: fixture.locations.identity)
    let invalid: [[String: JSONValue]] = [
        ["locale": .string("unknown")], ["environment": .object(["BAD=KEY": .string("value")])],
        ["overrides": .object(["unknown": .null])], ["overrides": .object(["dxvk": .integer(1)])],
        ["overrides": .object(["customResolutionWidth": .integer(10)])],
        ["overrides": .object(["dllOverrides": .array([.object(["dllName": .string("x=y"), "mode": .string("n")])])])]
    ]
    for patch in invalid {
        var params = fixture.params
        params["patch"] = .object(patch.merging(["arguments": .string("changed")]) { current, _ in current })
        await #expect(throws: BridgeFailure.self) {
            try await ProgramSettingsService.call("programs.settings.set", params: params, workspace: fixture.workspace)
        }
        #expect(try Data(contentsOf: fixture.locations.identity) == before)
    }
}

@Test @MainActor func portableHistoryDeletesSelectedRecordsAndPreservesUnknownData() throws {
    let fixture = try ProgramFixture()
    defer { fixture.remove() }
    let logDirectory = fixture.root.appendingPathComponent("logs")
    try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    let url = fixture.container.appendingPathComponent("Program Settings/game.exe.run-history.plist")
    let first = UUID().uuidString
    let second = UUID().uuidString
    let entries: [[String: Any]] = [first, second].map { id in [
        "id": id, "startTime": Date(timeIntervalSince1970: 100), "endTime": Date(timeIntervalSince1970: 105),
        "programName": "game.exe", "logFileName": "\(id).log", "exitCode": 0, "futureEntry": true
    ] }
    try fixture.write(["entries": entries, "futureHistory": "retained"], to: url)
    for id in [first, second] {
        try Data("log".utf8).write(to: logDirectory.appendingPathComponent("\(id).log"))
    }
    var params = fixture.params
    params["runID"] = .string(first)
    let result = try ProgramHistoryService.call(
        "programs.history.delete",
        params: params,
        workspace: fixture.workspace,
        logsDirectory: logDirectory
    )
    let remaining = try #require(result.object?["entries"]).decoded([JSONValue].self)
    #expect(remaining.count == 1)
    #expect(!FileManager.default.fileExists(atPath: logDirectory.appendingPathComponent("\(first).log").path))
    #expect(FileManager.default.fileExists(atPath: logDirectory.appendingPathComponent("\(second).log").path))
    let raw = try fixture.read(url)
    #expect(raw["futureHistory"] as? String == "retained")
    #expect((raw["entries"] as? [[String: Any]])?.first?["futureEntry"] as? Bool == true)
    #expect(try remaining.first?.object?["duration"]?.decoded(Double.self) == 5)
}

@Test @MainActor func portableHistoryRejectsImportedTraversalAndPreservesOriginalFile() throws {
    let fixture = try ProgramFixture()
    defer { fixture.remove() }
    let url = fixture.container.appendingPathComponent("Program Settings/game.exe.run-history.plist")
    try fixture.write(
        ["entries": [[
            "id": UUID().uuidString,
            "programName": "game.exe",
            "logFileName": "../outside.log",
            "startTime": Date()
        ]]],
        to: url
    )
    let before = try Data(contentsOf: url)
    #expect(throws: BridgeFailure.self) {
        try ProgramHistoryService.call("programs.history.delete", params: fixture.params, workspace: fixture.workspace)
    }
    #expect(try Data(contentsOf: url) == before)
}
