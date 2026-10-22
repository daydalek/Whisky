//
//  BridgeTests.swift
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
@testable import WhiskyApplication
import WhiskyBridgeProtocol
import WhiskyCore

private struct Fixture {
    let root: URL
    let container: URL
    let executable: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("whisky-bridge-\(UUID())")
        container = root.appendingPathComponent("容器 with spaces")
        executable = container.appendingPathComponent("drive_c/Game/test.exe")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x4D, 0x5A]).write(to: executable)
        let metadata: [String: Any] = [
            "info": ["name": "测试容器", "pins": [], "blocklist": []],
            "futureSetting": ["keep": true]
        ]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0)
            .write(to: container.appendingPathComponent("Metadata.plist"))
    }

    var params: [String: JSONValue] {
        ["container": .string(container.path), "executable": .string(executable.path)]
    }

    var workspace: ApplicationWorkspace {
        ApplicationWorkspace(containers: [container])
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Test func framesHandleUTF8FragmentsAndCRLF() throws {
    var framer = BridgeFramer()
    let bytes = Array("{\"文字\":\"日本語\"}\r\n{}\n".utf8)
    var frames: [Data] = []
    for byte in bytes {
        frames += try framer.append(Data([byte]))
    }
    #expect(frames.count == 2)
    #expect(String(data: frames[0], encoding: .utf8) == "{\"文字\":\"日本語\"}")
    try framer.finish()
}

@Test func boundedFramesAndTruncatedEOF() throws {
    var framer = BridgeFramer()
    #expect(throws: BridgeFailure.self) { try framer.append(Data(
        repeating: 65,
        count: BridgeFramer.maximumFrameBytes + 1
    )) }
    var partial = BridgeFramer()
    _ = try partial.append(Data("{".utf8))
    #expect(throws: BridgeFailure.self) { try partial.finish() }
}

@Test func pathsRequireAbsoluteNativeStrings() throws {
    #expect(throws: BridgeFailure.self) { try ["container": JSONValue.string("relative")].path("container") }
    let path = try ["container": JSONValue.string("/tmp/中文 空格")].path("container")
    #expect(path.path == "/tmp/中文 空格")
}

@Test @MainActor func versionAndUnknownCapabilityAreVisibleFailures() async {
    let service = ApplicationService(workspace: ApplicationWorkspace(containers: []))
    let mismatch = await service.respond(.init(id: "1", method: "workspace.containers", version: 99))
    #expect(mismatch.error?.code == "version_mismatch")
    let missing = await service.respond(.init(id: "2", method: "wine.download"))
    #expect(missing.error?.code == "method_unavailable")
    let describe = await service.respond(.init(id: "3", method: "bridge.describe"))
    #expect(describe.result?.object?["dateUnit"] == .string("unix_seconds"))
}

@Test func registryReadsPreserveCorruptionAndCanonicalizeAliases() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let registry = fixture.root.appendingPathComponent("BottleVM.plist")
    let original = Data("corrupt".utf8)
    try original.write(to: registry)
    let workspace = ApplicationWorkspace(registry: registry)
    #expect(throws: (any Error).self) { try workspace.catalogue() }
    #expect(try Data(contentsOf: registry) == original)
    let alias = fixture.root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.container)
    #expect(try ApplicationWorkspace(containers: [fixture.container, alias]).containers().count == 1)
}

@Test @MainActor func programSettingsPreserveUnknownKeysAndLegacyFallback() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let locations = ProgramStorageLayout.locations(for: fixture.executable, containerURL: fixture.container)
    try FileManager.default.createDirectory(
        at: locations.legacy.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let legacy: [String: Any] = ["arguments": "legacy", "future": "retained", "environment": ["EXTERNAL": "yes"]]
    let before = try PropertyListSerialization.data(fromPropertyList: legacy, format: .binary, options: 0)
    try before.write(to: locations.legacy)
    let service = ApplicationService(workspace: fixture.workspace)
    var params = fixture.params
    params["field"] = .string("arguments")
    params["value"] = .string("新 参数")
    let result = await service.respond(.init(id: "1", method: "configuration.set", params: params))
    #expect(result.error == nil)
    #expect(result.result?.object?["arguments"] == .string("新 参数"))
    let document = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: locations.identity),
        format: nil
    ) as? [String: Any]
    #expect(document?["future"] as? String == "retained")
    #expect(try Data(contentsOf: locations.legacy) == before)
}

@Test @MainActor func invalidSettingsAndUnavailableHostEffectsKeepMetadata() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let metadata = fixture.container.appendingPathComponent("Metadata.plist")
    let original = try Data(contentsOf: metadata)
    let service = ApplicationService(workspace: fixture.workspace)
    let bad = await service.respond(.init(id: "1", method: "configuration.set", params: [
        "container": .string(fixture.container.path), "field": .string("windowsVersion"), "value": .string("bogus")
    ]))
    #expect(bad.error != nil)
    let host = await service.respond(.init(id: "2", method: "configuration.set", params: [
        "container": .string(fixture.container.path), "field": .string("windowsVersion"), "value": .string("win11")
    ]))
    #expect(host.error?.code == "capability_unavailable")
    #expect(try Data(contentsOf: metadata) == original)
}

@Test @MainActor func pinCatalogueRatingAndVisibilityUseRealStorage() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let service = ApplicationService(workspace: fixture.workspace)
    var params = fixture.params
    params["name"] = .string("中文游戏")
    params["pinned"] = .bool(true)
    let pinned = await service.respond(.init(id: "1", method: "programs.pin", params: params))
    #expect(pinned.error == nil)
    let entries = try await service.call("library.entries", params: ["container": .string(fixture.container.path)])
    guard case let .array(rows) = entries,
          let id = rows.first?.object?["id"]?.string
    else { Issue.record("missing real pinned entry")
        return
    }
    var entry: [String: JSONValue] = [
        "container": .string(fixture.container.path),
        "entryID": .string(id),
        "rating": .integer(8)
    ]
    let rating = try await service.call("entry.rating", params: entry)
    #expect(rating.object?["rating"] == .integer(8))
    entry["hidden"] = .bool(true)
    _ = try await service.call("entry.hidden", params: entry)
    let actual = try await fixture.workspace.entry(entry)
    #expect(try LibraryPresentation.load(for: actual).activity.rating == 8)
    #expect(try !LibraryVisibility.load(bottleURL: fixture.container).includes(actual))
    let metadata = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: fixture.container.appendingPathComponent("Metadata.plist")),
        format: nil
    ) as? [String: Any]
    #expect((metadata?["futureSetting"] as? [String: Bool])?["keep"] == true)
}

@Test @MainActor func foreignContainerWritesAreRejected() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let service = ApplicationService(workspace: fixture.workspace)
    let response = await service.respond(.init(id: "1", method: "environment.set", params: [
        "container": .string(fixture.root.path), "key": .string("X"), "value": .string("Y")
    ]))
    #expect(response.error?.code == "unknown_container")
}

@Test func datesAndLargeIDsRoundTripAcrossJSON() throws {
    let value = try JSONValue.encoded(Date(timeIntervalSince1970: 1_700_000_000.5))
    #expect(try value.decoded(Date.self) == Date(timeIntervalSince1970: 1_700_000_000.5))
    let request = BridgeRequest(id: "18446744073709551615", method: "bridge.describe")
    #expect(try JSONDecoder().decode(BridgeRequest.self, from: JSONEncoder().encode(request)).id == request.id)
}

@Test @MainActor func environmentEditsValidateAndReadBackLiteralText() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let service = ApplicationService(workspace: fixture.workspace)
    var params = fixture.params
    params["key"] = .string("GAME_PATH")
    params["value"] = .string("中文 $HOME `literal` \\")
    let response = await service.respond(.init(id: "1", method: "environment.set", params: params))
    #expect(response.result?.object?["GAME_PATH"] == params["value"])
    params["key"] = .string("BAD=NAME")
    let failure = await service.respond(.init(id: "2", method: "environment.set", params: params))
    #expect(failure.error != nil)
}

@MainActor private final class MemoryClipboard: ClipboardAccess {
    var value = ClipboardSnapshot(kind: .text, sizeBytes: 100_000, textPreview: "original", version: "1")
    var cleared = 0
    func snapshot() -> ClipboardSnapshot {
        value
    }

    func clear(ifMatches snapshot: ClipboardSnapshot) -> Bool {
        guard value.version == snapshot.version else { return false }
        cleared += 1
        value = .init(kind: .empty, sizeBytes: 0, version: "cleared")
        return true
    }
}

@Test @MainActor func launchPromptUsesSingleEntryBoundVersionedDecision() throws {
    let clipboard = MemoryClipboard(), broker = LaunchInteractionBroker()
    let prompt = broker.assess(
        entryID: "game-A",
        clipboard: clipboard,
        launcher: nil,
        policy: .alwaysWarn,
        threshold: 100
    )
    let token = try #require(prompt?.object?["interaction"]?.object?["token"]?.string)
    #expect(throws: BridgeFailure.self) { try broker.resolve(
        token: token,
        entryID: "game-B",
        decision: "clear",
        clipboard: clipboard
    ) }
    #expect(clipboard.cleared == 0)
    try broker.resolve(token: token, entryID: "game-A", decision: "keep", clipboard: clipboard)
    #expect(throws: BridgeFailure.self) { try broker.resolve(
        token: token,
        entryID: "game-A",
        decision: "clear",
        clipboard: clipboard
    ) }
    #expect(clipboard.cleared == 0)
}

@Test @MainActor func stalePromptPreservesReplacementClipboard() throws {
    let clipboard = MemoryClipboard(), broker = LaunchInteractionBroker()
    let prompt = broker.assess(
        entryID: "game",
        clipboard: clipboard,
        launcher: nil,
        policy: .alwaysWarn,
        threshold: 100
    )
    let token = try #require(prompt?.object?["interaction"]?.object?["token"]?.string)
    clipboard.value = .init(kind: .text, sizeBytes: 90_000, textPreview: "replacement", version: "2")
    #expect(throws: BridgeFailure.self) { try broker.resolve(
        token: token,
        entryID: "game",
        decision: "clear",
        clipboard: clipboard
    ) }
    #expect(clipboard.value.version == "2")
    #expect(clipboard.cleared == 0)
}

@Test @MainActor func programBlocklistPreservesPinnedLibraryParity() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let configuration = ConfigurationFile(
        url: fixture.container.appendingPathComponent("Metadata.plist"),
        locking: HostFileLock()
    )
    try await configuration.setPinned(true, executable: fixture.executable, name: "Pinned")
    try await configuration.setBlocked(true, executable: fixture.executable)
    let pins = try await configuration.pinnedPrograms()
    #expect(pins.count == 1 && pins[0].blocked)
    let entries = try await fixture.workspace.entries(in: fixture.container)
    #expect(entries.contains { $0.name == "Pinned" })
}

@Test @MainActor func applicationPreferencesUseTypedAllowlistedSharedKeys() throws {
    let name = "com.whisky.preferences.bridge.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let service = PreferencesService(defaults: defaults, defaultBottleDirectory: URL(fileURLWithPath: "/tmp/Bottles"))
    let value = try service.call("preferences.set", params: ["key": .string("offlineMode"), "value": .bool(true)])
    #expect(value.object?["offlineMode"] == .bool(true))
    #expect(UserDefaults(suiteName: name)?.bool(forKey: "offlineMode") == true)
    #expect(throws: BridgeFailure.self) { try service.call(
        "preferences.set",
        params: ["key": .string("offlineMode"), "value": .string("false")]
    ) }
    #expect(throws: BridgeFailure.self) { try service.call(
        "preferences.set",
        params: ["key": .string("unrelatedPreference"), "value": .bool(true)]
    ) }
}

@Test @MainActor func preferenceSchemaCoversTheSwiftUIAppStorageSurface() throws {
    let name = "com.whisky.preferences.schema.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let service = PreferencesService(defaults: defaults, defaultBottleDirectory: URL(fileURLWithPath: "/tmp/Bottles"))
    let schema = try service.call("preferences.schema", params: [:])
    let booleans = try #require(schema.object?["booleans"]?.object)
    let strings = try #require(schema.object?["strings"]?.object)
    for key in [
        "offlineMode", "killOnTerminate", "showMenuBarExtra", "checkWhiskyWineUpdates",
        "libraryRefreshAfterExit", "libraryDetailBlurredBackground", "librarySingleLineTitles",
        "libraryCenterWideCoverText", "libraryMixedCoverLayout", "libraryBlurredCoverFill"
    ] {
        #expect(booleans[key] != nil)
    }
    for key in [
        "preferredTerminal", "libraryCoverFillStyle", "libraryDisplayMode", "librarySort",
        "libraryDetailLayoutStyle", "libraryMetadataEnabledSources", "telemetryConsent"
    ] {
        #expect(strings[key] != nil)
    }
    #expect(booleans["libraryMixedCoverLayout"] == .bool(true))
    #expect(strings["libraryDisplayMode"] == .string("covers"))
    let read = try service.call("preferences.read", params: [:])
    #expect(read.object?["librarySort"] == .string("recent"))
    #expect(read.object?["defaultBottleLocation"] == .string("/tmp/Bottles"))
    defaults.set("/tmp/Chosen Bottles", forKey: "defaultBottleLocation")
    _ = try service.call("preferences.set", params: [
        "key": .string("libraryDisplayMode"), "value": .string("timeline")
    ])
    let updated = try service.call("preferences.read", params: [:])
    #expect(updated.object?["libraryDisplayMode"] == .string("timeline"))
    #expect(updated.object?["defaultBottleLocation"] == .string("/tmp/Chosen Bottles"))
    #expect(throws: BridgeFailure.self) { try service.call(
        "preferences.set",
        params: ["key": .string("telemetryConsent"), "value": .bool(true)]
    ) }
}

@Test @MainActor func explicitShutdownClosesSessionAndRemainsIdempotent() async {
    let service = ApplicationService(workspace: ApplicationWorkspace())
    let reply = await service.respond(.init(id: "1", method: "bridge.shutdown"))
    #expect(reply.result?.object?["accepted"] == .bool(true))
    let after = await service.respond(.init(id: "2", method: "bridge.describe"))
    #expect(after.error?.code == "session_closed")
    await service.shutdown()
}

@Test @MainActor func applicationInfoIsPortableAndAdvertised() async throws {
    let service = ApplicationService(workspace: ApplicationWorkspace())
    let info = try await service.call("system.info", params: [:])
    #expect(info.object?["appName"]?.string?.isEmpty == false)
    #expect(info.object?["appVersion"]?.string?.isEmpty == false)
    #expect(info.object?["osVersion"]?.string?.isEmpty == false)
    #expect(ApplicationService.methods.contains("system.info"))
}

@Test @MainActor func retainedCataloguePagesHaveStableIdentityAndValidatedBounds() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let service = ApplicationService(workspace: fixture.workspace)
    var params = fixture.params
    params["name"] = .string("Pinned")
    params["pinned"] = .bool(true)
    _ = try await service.call("programs.pin", params: params)
    let start = try await service.call("library.scan", params: fixture.params)
    let id = try #require(start.object?["jobID"]?.string)
    var snapshotID: String?
    for _ in 0 ..< 2_000 {
        let state = try await service.call("jobs.get", params: ["jobID": .string(id)])
        if state.object?["status"] == .string("completed") {
            snapshotID = state.object?["result"]?.object?["snapshotID"]?.string
            break
        }
        #expect(state.object?["status"] != .string("failed"))
        await Task.yield()
    }
    let snapshot = try #require(snapshotID)
    let page = try await service.call("library.page", params: ["snapshotID": .string(snapshot), "limit": .integer(1)])
    #expect(page.object?["total"] == .integer(1))
    #expect(page.object?["nextOffset"] == .null)
    let bad = await service.respond(.init(id: "bad", method: "library.page", params: [
        "snapshotID": .string(snapshot), "offset": .integer(-1)
    ]))
    #expect(bad.error?.code == "invalid_params")
    await service.shutdown()
}
