//
//  RuntimeLaunchRegistrationTests.swift
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

private extension JSONValue {
    var arrayValues: [JSONValue]? {
        if case let .array(values) = self {
            values
        } else {
            nil
        }
    }
}

@MainActor
private final class RegistrationDriver: LibraryRuntimeDriver {
    let snapshot = LibraryRuntimeDriverSnapshot()
    var configurations: [[LibraryEntry]] = []
    let launches = AsyncStream<String>.makeStream()

    func events() -> AsyncStream<LibraryRuntimeDriverEvent> {
        AsyncStream { $0.finish() }
    }

    func capabilities(for entry: LibraryEntry) -> LibraryRuntimeCapabilities {
        [.launch, .cancelLaunch]
    }

    func retainContainers(_ urls: Set<URL>) {}
    func configure(entries: [LibraryEntry], containerURL: URL) async {
        configurations.append(entries)
    }

    func launchProgram(
        _ request: LibraryLaunchRequest, onStarted: @escaping @MainActor () -> Void
    ) async -> LaunchResult {
        launches.continuation.yield(request.entry.id)
        onStarted()
        return .launchedSuccessfully(programName: request.entry.name)
    }

    func programDidStart(_ request: LibraryLaunchRequest) {}
    func launchSteam(_ entry: LibraryEntry) {
        launches.continuation.yield(entry.id)
    }

    func cancelSteamLaunch(_ entry: LibraryEntry) {}
    func stop(_ entry: LibraryEntry) async {}
    func stopTracking() {
        launches.continuation.finish()
    }
}

private struct RegistrationFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("whisky-registration-\(UUID())")
    var container: URL {
        root.appendingPathComponent("Bottle")
    }

    var workspace: ApplicationWorkspace {
        ApplicationWorkspace(containers: [container])
    }

    init() throws {
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let metadata: [String: Any] = ["info": ["name": "Test", "pins": [], "blocklist": []]]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
            .write(to: container.appendingPathComponent("Metadata.plist"))
    }

    func addEntry(_ source: String) async throws -> LibraryEntry {
        if source == "steam" {
            let steam = container.appendingPathComponent("drive_c/Program Files (x86)/Steam")
            let apps = steam.appendingPathComponent("steamapps")
            try FileManager.default.createDirectory(
                at: apps.appendingPathComponent("common/Test Game"), withIntermediateDirectories: true
            )
            try Data().write(to: steam.appendingPathComponent("steam.exe"))
            try Data(#"""
            "AppState" { "appid" "440" "name" "Test Game" "installdir" "Test Game" "StateFlags" "4" }
            """#.utf8).write(to: apps.appendingPathComponent("appmanifest_440.acf"))
        } else {
            let folder = container.appendingPathComponent("drive_c/Test Game")
            let executable = folder.appendingPathComponent("play.exe")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data([0x4D, 0x5A]).write(to: executable)
            if source == "pinned" {
                let file = ConfigurationFile(
                    url: container.appendingPathComponent("Metadata.plist"), locking: HostFileLock()
                )
                try await file.setPinned(true, executable: executable, name: "Test Game")
            } else {
                var folders = FolderGameLibrary()
                folders.assignedFolders = [folder.path]
                folders.executables[FolderGameLibrary.key(for: folder, bottleURL: container)] =
                    FolderGameLibrary.key(for: executable, bottleURL: container)
                try folders.save(bottleURL: container)
            }
        }
        return try #require(try await workspace.entries(in: container).first { $0.source.rawValue == source })
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Runtime launch registration", .timeLimit(.minutes(1)))
struct RuntimeLaunchRegistrationTests {
    @Test(arguments: ["pinned", "folder", "steam"], ["firstLaunch", "newEntry", "invalidated", "configured"])
    @MainActor func launchRegistersLiveEntry(source: String, scenario: String) async throws {
        let fixture = try RegistrationFixture()
        defer { fixture.remove() }
        let driver = RegistrationDriver()
        let runtime = RuntimeService(driver: driver, backendResolver: { _, _ in "DXMT" })
        let service = ApplicationService(workspace: fixture.workspace, runtime: runtime)
        defer { runtime.stopTracking() }
        let container: [String: JSONValue] = ["container": .string(fixture.container.path)]
        if scenario == "newEntry" {
            _ = try await service.call("runtime.configure", params: container)
        }
        let entry = try await fixture.addEntry(source)
        if scenario == "invalidated" || scenario == "configured" {
            _ = try await service.call("runtime.configure", params: container)
        }
        if scenario == "invalidated" {
            runtime.invalidate(container: fixture.container)
        }
        let response = await service.respond(.init(id: "launch", method: "runtime.launch", params: [
            "container": .string(fixture.container.path), "entryID": .string(entry.id)
        ]))
        #expect(response.error == nil)
        try #require(response.result?.object?["accepted"] == .bool(true))
        #expect(response.result?.object?["backend"] == .string("DXMT"))
        #expect(driver.configurations.last?.contains { $0.id == entry.id } == true)
        #expect(driver.configurations.count == (scenario == "newEntry" || scenario == "invalidated" ? 2 : 1))
        var iterator = driver.launches.stream.makeAsyncIterator()
        let started = await iterator.next()
        #expect(started == entry.id)
        let snapshot = try await service.call("runtime.snapshot", params: [:])
        #expect(snapshot.object?["entries"]?.arrayValues?.contains { $0.object?["id"] == .string(entry.id) } == true)
    }

    @Test @MainActor func unknownEntryKeepsWorkspaceValidation() async throws {
        let fixture = try RegistrationFixture()
        defer { fixture.remove() }
        let driver = RegistrationDriver()
        let runtime = RuntimeService(driver: driver)
        let service = ApplicationService(workspace: fixture.workspace, runtime: runtime)
        defer { runtime.stopTracking() }
        let response = await service.respond(.init(id: "unknown", method: "runtime.launch", params: [
            "container": .string(fixture.container.path), "entryID": .string("missing")
        ]))
        #expect(response.error?.code == "unknown_entry")
        #expect(driver.configurations.isEmpty)
    }
}
