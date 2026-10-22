//
//  RuntimeAndLinuxBridgeTests.swift
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
import WhiskyCore

@MainActor
private final class PortableTestDriver: LibraryRuntimeDriver {
    var snapshot = LibraryRuntimeDriverSnapshot()
    private var continuation: AsyncStream<LibraryRuntimeDriverEvent>.Continuation?
    var startedRequests: [LibraryLaunchRequest] = []
    var stoppedEntries: [String] = []

    func events() -> AsyncStream<LibraryRuntimeDriverEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.yield(.changed(self.snapshot))
        }
    }

    func capabilities(for entry: LibraryEntry) -> LibraryRuntimeCapabilities {
        [.launch, .cancelLaunch, .stop, .terminal]
    }

    func retainContainers(_ urls: Set<URL>) {}
    func configure(entries: [LibraryEntry], containerURL: URL) async {}

    func launchProgram(
        _ request: LibraryLaunchRequest,
        onStarted: @escaping @MainActor () -> Void
    ) async -> LaunchResult {
        onStarted()
        return .launchedSuccessfully(programName: request.entry.name)
    }

    func programDidStart(_ request: LibraryLaunchRequest) {
        startedRequests.append(request)
        snapshot.revision &+= 1
        snapshot.observation.runningEntryIDs.insert(request.entry.id)
        continuation?.yield(.changed(snapshot))
    }

    func launchSteam(_ entry: LibraryEntry) {}
    func cancelSteamLaunch(_ entry: LibraryEntry) {}

    func stop(_ entry: LibraryEntry) async {
        stoppedEntries.append(entry.id)
        snapshot.revision &+= 1
        snapshot.observation.runningEntryIDs.remove(entry.id)
        snapshot.observation.endedEntryIDs = [entry.id]
        continuation?.yield(.changed(snapshot))
    }

    func stopTracking() {}
}

@MainActor
private final class TestClipboard: ClipboardAccess {
    var value = ClipboardSnapshot(kind: .text, sizeBytes: 64_000, textPreview: "secret", version: "v1")
    func snapshot() -> ClipboardSnapshot {
        value
    }

    func clear(ifMatches snapshot: ClipboardSnapshot) -> Bool {
        guard value.version == snapshot.version else { return false }
        value = .init(kind: .empty, sizeBytes: 0, version: "v2")
        return true
    }
}

@Suite("Portable runtime, folders and Linux bridge services")
struct RuntimeAndLinuxBridgeTests {
    // swiftlint:disable:next function_body_length
    @Test @MainActor func portableRuntimeServiceDrivesLaunchInteractionAndEvents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whisky-rt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let container = root.appendingPathComponent("Bottle")
        let executable = container.appendingPathComponent("drive_c/Game/play.exe")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x4D, 0x5A]).write(to: executable)
        let metadata: [String: Any] = [
            "info": ["name": "Portable", "pins": [], "blocklist": []],
            "cleanupConfig": ["clipboardPolicy": "warn", "clipboardThreshold": 1_024]
        ]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
            .write(to: container.appendingPathComponent("Metadata.plist"))

        let workspace = ApplicationWorkspace(containers: [container])
        let driver = PortableTestDriver()
        let clipboard = TestClipboard()
        let runtime = RuntimeService(driver: driver, clipboard: { clipboard })
        let service = ApplicationService(workspace: workspace, runtime: runtime)

        _ = try await service.call("programs.pin", params: [
            "container": .string(container.path),
            "executable": .string(executable.path),
            "name": .string("Play"),
            "pinned": .bool(true)
        ])
        let configured = try await service.call("runtime.configure", params: ["container": .string(container.path)])
        let entryID = try #require(configured.object?["entries"]?.arrayValues?.first?.object?["id"]?.string)

        let prompt = try await service.call("runtime.launch", params: [
            "container": .string(container.path),
            "entryID": .string(entryID)
        ])
        #expect(prompt.object?["accepted"] == .bool(false))
        let token = try #require(prompt.object?["interaction"]?.object?["token"]?.string)

        let launched = try await service.call("runtime.launch", params: [
            "container": .string(container.path),
            "entryID": .string(entryID),
            "interactionToken": .string(token),
            "clipboardDecision": .string("clear")
        ])
        #expect(launched.object?["accepted"] == .bool(true))
        #expect(clipboard.value.kind == .empty)

        for _ in 0 ..< 50 where driver.startedRequests.isEmpty {
            await Task.yield()
        }
        #expect(driver.startedRequests.count == 1)

        let events = try await service.call("runtime.events", params: ["after": .string("0")])
        #expect(events.object?["resyncRequired"] == .bool(false))
        let stopped = try await service.call("runtime.stop", params: [
            "container": .string(container.path),
            "entryID": .string(entryID)
        ])
        #expect(stopped.object?["accepted"] == .bool(true))
        #expect(driver.stoppedEntries == [entryID])
        await service.shutdown()
    }

    @Test @MainActor func helperCompositionAdvertisesRuntimeAndSnapshotsWithoutAGame() async throws {
        let runtime = RuntimeService(driver: UnavailableLibraryRuntimeDriver())
        let service = ApplicationService(workspace: ApplicationWorkspace(containers: []), runtime: runtime)

        let describe = await service.respond(.init(id: "1", method: "bridge.describe"))
        let methods = try #require(describe.result?.object?["methods"]?.arrayValues?
            .compactMap { $0.string })
        for method in RuntimeService.methods {
            #expect(methods.contains(method))
        }
        let capabilities = try #require(describe.result?.object?["capabilities"]?.arrayValues?
            .compactMap { $0.string })
        for capability in RuntimeService.capabilities {
            #expect(capabilities.contains(capability))
        }

        let snapshot = await service.respond(.init(id: "2", method: "runtime.snapshot"))
        #expect(snapshot.error == nil)
        #expect(snapshot.result?.object?["sequence"] == .string("0"))
        #expect(snapshot.result?.object?["entries"]?.arrayValues?.isEmpty == true)
        #expect(snapshot.result?.object?["queryFailures"]?.object?.isEmpty == true)

        let events = await service.respond(.init(id: "3", method: "runtime.events", params: [
            "after": .string("0")
        ]))
        #expect(events.error == nil)
        #expect(events.result?.object?["events"]?.arrayValues?.isEmpty == true)
        #expect(events.result?.object?["resyncRequired"] == .bool(false))
        #expect(events.result?.object?["snapshot"]?.object?["sequence"] == .string("0"))
        await service.shutdown()
    }

    @Test @MainActor func foldersBridgeMethodsManageRootsAssignmentsExclusionsAndExecutables() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whisky-folders-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let container = root.appendingPathComponent("Bottle")
        let gamesRoot = container.appendingPathComponent("drive_c/Games")
        let gameFolder = gamesRoot.appendingPathComponent("Touhou")
        let exe = gameFolder.appendingPathComponent("TH06.EXE")
        try FileManager.default.createDirectory(at: gameFolder, withIntermediateDirectories: true)
        try Data([0x4D, 0x5A]).write(to: exe)

        let service = ApplicationService(workspace: ApplicationWorkspace(containers: [container]))
        let added = try await service.call("folders.addRoot", params: [
            "container": .string(container.path),
            "path": .string(gamesRoot.path)
        ])
        #expect(added.object?["roots"]?.arrayValues == [.string(gamesRoot.path)])

        let assigned = try await service.call("folders.assign", params: [
            "container": .string(container.path),
            "path": .string(gameFolder.path),
            "assigned": .bool(true)
        ])
        #expect(assigned.object?["assignedFolders"]?.arrayValues == [.string(gameFolder.path)])

        let bound = try await service.call("folders.executable", params: [
            "container": .string(container.path),
            "path": .string(gameFolder.path),
            "executable": .string(exe.path)
        ])
        #expect(bound.object?["executables"]?.object?[gameFolder.path] == .string(exe.path))

        let entries = try await service.call("library.entries", params: ["container": .string(container.path)])
        #expect(entries.arrayValues?.first?.object?["icon"] == .string(exe.path))
        #expect(entries.arrayValues?.first?.object?["folder"] == .string(gameFolder.path))

        let candidatesFromFile = try await service.call("folders.candidates", params: [
            "container": .string(container.path),
            "path": .string(exe.path)
        ])
        #expect(candidatesFromFile.object?["folder"] == .string(gameFolder.path))

        let excluded = try await service.call("folders.exclude", params: [
            "container": .string(container.path),
            "path": .string(gameFolder.path),
            "excluded": .bool(true)
        ])
        #expect(excluded.object?["excludedFolders"]?.arrayValues == [.string(gameFolder.path)])
    }

    @Test @MainActor func linuxApplicationServicesAndSchemaPlatformFilter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whisky-linux-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let container = root.appendingPathComponent("Bottle")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fakeWine = bin.appendingPathComponent("wine")
        try Data("#!/bin/sh\n".utf8).write(to: fakeWine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeWine.path)
        let file = container.appendingPathComponent("readme.txt")
        try Data("ok".utf8).write(to: file)

        let opened = LockBox<URL?>()
        let linux = LinuxApplicationServices(searchPaths: [bin]) { url in
            opened.set(url)
        }
        let service = ApplicationService(workspace: ApplicationWorkspace(containers: [container]), native: linux)
        let resources = try await service.call("system.resources", params: [:])
        #expect(resources.object?["tools"]?.object?["wine"] == .string(fakeWine.path))

        _ = try await service.call("system.reveal", params: [
            "container": .string(container.path),
            "path": .string(file.path)
        ])
        #expect(opened.get()?.path == container.path)

        let schema = try await service.call("configuration.schema", params: ["platform": .string("linux")])
        let ids = Set((schema.arrayValues ?? []).compactMap { $0.object?["id"]?.string })
        #expect(!ids.contains("metalFX"))
        #expect(ids.contains("dxvkAsync"))
    }

    @Test func procStatStartTimeAndProcessIdentityProvider() {
        let stat = "4242 (game (final) v2.exe) S 1 4242 4242 0 -1 4194304 100 0 0 0 10 5 0 0 20 0 4 0 987654321 1234"
        #expect(LinuxProcStatParser.startTime(from: stat) == 987_654_321)
        let provider = HostProcessIdentityProvider()
        let current = provider.currentProcess
        #expect(current.pid > 0)
        #expect(provider.isAlive(current))
        #expect(!provider.isAlive(HostProcessIdentity(pid: -1, birth: 1)))
    }
}

private final class LockBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value = nil) where Value: ExpressibleByNilLiteral {
        self.value = value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private extension JSONValue {
    var arrayValues: [Self]? {
        if case let .array(values) = self {
            values
        } else {
            nil
        }
    }
}
