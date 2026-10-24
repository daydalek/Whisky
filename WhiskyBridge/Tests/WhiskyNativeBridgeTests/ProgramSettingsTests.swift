//
//  ProgramSettingsTests.swift
//  WhiskyNativeBridgeTests
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
import WhiskyKit
@testable import WhiskyNativeBridge

private struct Fixture {
    let root: URL
    let container: URL
    let executable: URL
    let settingsURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("whisky-program-\(UUID())")
        container = root.appendingPathComponent("Bottle")
        executable = container.appendingPathComponent("drive_c/Game/game.exe")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x4D, 0x5A]).write(to: executable)
        let metadata: [String: Any] = ["info": ["name": "Program Test", "pins": [], "blocklist": []]]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0)
            .write(to: container.appendingPathComponent("Metadata.plist"))
        settingsURL = ProgramStorageLayout.locations(
            for: executable,
            containerURL: container
        ).identity
        let seeded: [String: Any] = [
            "arguments": "-old",
            "futureKey": ["keep": true]
        ]
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try PropertyListSerialization.data(fromPropertyList: seeded, format: .xml, options: 0)
            .write(to: settingsURL)
    }

    var workspace: ApplicationWorkspace {
        ApplicationWorkspace(containers: [container])
    }

    var params: [String: JSONValue] {
        [
            "container": .string(container.path),
            "executable": .string(executable.path)
        ]
    }

    func storedSettings() throws -> [String: Any] {
        let data = try Data(contentsOf: settingsURL)
        guard let raw = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any]
        else { throw CocoaError(.fileReadCorruptFile) }
        return raw
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor private func services(wineEnabled: Bool = false) -> MacOSApplicationServices {
    MacOSApplicationServices(
        wineEnabled: wineEnabled,
        preferencesDomain: "com.franke.Whisky.tests.\(UUID().uuidString)",
        jobs: BridgeJobStore()
    )
}

@Test @MainActor func programSettingsPatchPreservesUnknownKeysAndClearsOverrides() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let service = services()
    var params = fixture.params
    params["patch"] = .object([
        "locale": .string("ja_JP.UTF-8"),
        "arguments": .string("-windowed"),
        "environment": .object(["GAME": .string("中文")]),
        "overrides": .object([
            "graphicsBackend": .string("dxvk"),
            "virtualDesktopEnabled": .bool(true),
            "resolutionPreset": .string("custom"),
            "customResolutionWidth": .integer(1_280),
            "customResolutionHeight": .integer(720),
            "dllOverrides": .array([
                .object(["dllName": .string("dxgi"), "mode": .string("n,b")])
            ])
        ])
    ])
    let saved = try await service.programsCall(
        "programs.settings.set",
        params: params,
        workspace: fixture.workspace
    )
    #expect(saved.object?["locale"] == .string("ja_JP.UTF-8"))
    #expect(saved.object?["arguments"] == .string("-windowed"))
    #expect(saved.object?["environment"]?.object?["GAME"] == .string("中文"))
    #expect(saved.object?["overrides"]?.object?["graphicsBackend"] == .string("dxvk"))

    var stored = try fixture.storedSettings()
    #expect(stored["futureKey"] as? [String: Bool] == ["keep": true])
    #expect(stored["locale"] as? String == "ja_JP.UTF-8")
    #expect((stored["overrides"] as? [String: Any])?["dllOverrides"] != nil)

    params["patch"] = .object(["overrides": .null])
    _ = try await service.programsCall(
        "programs.settings.set",
        params: params,
        workspace: fixture.workspace
    )
    stored = try fixture.storedSettings()
    #expect(stored["overrides"] == nil)
    #expect(stored["futureKey"] as? [String: Bool] == ["keep": true])
}

@Test @MainActor func programSettingsRejectUnknownValuesAndReadEmptyHistory() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let service = services()
    var params = fixture.params
    params["patch"] = .object(["overrides": .object(["graphicsBackend": .string("bogus")])])
    await #expect(throws: BridgeFailure.self) {
        _ = try await service.programsCall(
            "programs.settings.set",
            params: params,
            workspace: fixture.workspace
        )
    }
    let history = try await service.programsCall(
        "programs.history.read",
        params: fixture.params,
        workspace: fixture.workspace
    )
    #expect(history.object?["entries"] == .array([]))
}

@Test @MainActor func sharedProgramStorageRoundTripsNativeModelsAndHistory() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    var settings = ProgramSettings()
    settings.lastLogFileURL = URL(fileURLWithPath: "/tmp/native.log")
    settings.lastDiagnosisDate = Date(timeIntervalSince1970: 1_000)
    var overrides = ProgramOverrides()
    overrides.dxvkHud = .fps
    overrides.enhancedSync = .esync
    overrides.dllOverrides = [DLLOverrideEntry(dllName: "dxgi", mode: .nativeThenBuiltin)]
    settings.overrides = overrides
    try PropertyListEncoder().encode(settings).write(to: fixture.settingsURL)
    var params = fixture.params
    params["patch"] = .object(["arguments": .string("--portable"), "locale": .string("ja_JP.UTF-8")])
    let result = try await ProgramSettingsService.call(
        "programs.settings.set",
        params: params,
        workspace: fixture.workspace
    )
    #expect(result.object?["lastLogFile"] == .string("/tmp/native.log"))
    let decoded = try PropertyListDecoder().decode(ProgramSettings.self, from: Data(contentsOf: fixture.settingsURL))
    #expect(decoded.arguments == "--portable")
    #expect(decoded.overrides == settings.overrides)
    #expect(decoded.lastDiagnosisDate == settings.lastDiagnosisDate)
    #expect(decoded.environment["LANG"] == "ja_JP.UTF-8")
    var history = RunLogHistory()
    let run = RunLogEntry(programName: "game.exe", logFileName: "native.log")
    history.append(run)
    let historyURL = RunLogStore.historyURL(for: "game.exe", in: fixture.container)
    try PropertyListEncoder().encode(history).write(to: historyURL)
    let read = try ProgramHistoryService.call(
        "programs.history.read",
        params: fixture.params,
        workspace: fixture.workspace
    )
    let entries = try #require(read.object?["entries"]).decoded([JSONValue].self)
    #expect(entries.first?.object?["id"] == .string(run.id.uuidString))
}

@Test @MainActor func programRunValidatesRunnableExtensionsAndStartsJob() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let service = services(wineEnabled: true)

    let txtFile = fixture.container.appendingPathComponent("drive_c/readme.txt")
    try Data("hello".utf8).write(to: txtFile)
    await #expect(throws: BridgeFailure.self) {
        _ = try await service.programsCall(
            "programs.run",
            params: ["container": .string(fixture.container.path), "executable": .string(txtFile.path)],
            workspace: fixture.workspace
        )
    }

    let missing = fixture.container.appendingPathComponent("drive_c/missing.exe")
    await #expect(throws: BridgeFailure.self) {
        _ = try await service.programsCall(
            "programs.run",
            params: ["container": .string(fixture.container.path), "executable": .string(missing.path)],
            workspace: fixture.workspace
        )
    }

    let reply = try await service.programsCall(
        "programs.run",
        params: ["container": .string(fixture.container.path), "executable": .string(fixture.executable.path)],
        workspace: fixture.workspace
    )
    #expect(reply.object?["jobID"]?.string?.isEmpty == false)
}
