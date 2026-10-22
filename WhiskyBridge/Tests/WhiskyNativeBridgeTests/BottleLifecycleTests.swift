//
//  BottleLifecycleTests.swift
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

private struct LifecycleFixture {
    let root: URL
    let container: URL
    let registryURL: URL

    init(name: String = "Original") throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisky-lifecycle-\(UUID())")
        container = root.appendingPathComponent("Bottle")
        registryURL = root.appendingPathComponent("BottleVM.plist")
        try FileManager.default.createDirectory(
            at: container.appendingPathComponent("drive_c"),
            withIntermediateDirectories: true
        )
        try Self.writeMetadata(to: container, name: name)
        var registry = BottleData(registryURL: registryURL)
        registry.paths = [container]
    }

    var workspace: ApplicationWorkspace {
        ApplicationWorkspace(registry: registryURL)
    }

    func registryPaths() -> [URL] {
        BottleData(registryURL: registryURL).paths
    }

    func storedName(at url: URL) throws -> String {
        struct Metadata: Decodable {
            struct Info: Decodable { let name: String }
            let info: Info
        }
        let data = try Data(contentsOf: url.appendingPathComponent("Metadata.plist"))
        return try PropertyListDecoder().decode(Metadata.self, from: data).info.name
    }

    static func writeMetadata(to bottle: URL, name: String) throws {
        let metadata: [String: Any] = ["info": ["name": name, "pins": [], "blocklist": []]]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0)
            .write(to: bottle.appendingPathComponent("Metadata.plist"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor private func lifecycleService() -> MacOSApplicationServices {
    MacOSApplicationServices(
        wineEnabled: true,
        preferencesDomain: "com.franke.Whisky.lifecycle.\(UUID().uuidString)",
        jobs: BridgeJobStore()
    )
}

@MainActor private func waitForJob(
    _ service: MacOSApplicationServices,
    _ jobID: String
) async throws -> JSONValue? {
    for _ in 0 ..< 200 {
        let record = try service.jobs.call("jobs.get", params: ["jobID": .string(jobID)])
        let status = record.object?["status"]?.string
        if status == "completed" {
            return record.object?["result"]
        }
        if status == "failed" || status == "cancelled" {
            let error = record.object?["error"]?.object
            let reason = error?["message"]?.string ?? status ?? "failed"
            throw BridgeFailure("test_job_failed", reason)
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw BridgeFailure("test_timeout", "Job did not finish")
}

@Test @MainActor func renameWritesMetadata() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let service = lifecycleService()
    let reply = try await service.bottleCall(
        "bottle.rename",
        params: [
            "container": .string(fixture.container.path),
            "name": .string("Renamed")
        ],
        workspace: fixture.workspace
    )
    #expect(reply.object?["name"] == .string("Renamed"))
    #expect(try fixture.storedName(at: fixture.container) == "Renamed")
}

@Test @MainActor func duplicateCopiesBottleAndRegistersIt() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let service = lifecycleService()
    let started = try await service.bottleCall(
        "bottle.duplicate",
        params: [
            "container": .string(fixture.container.path),
            "name": .string("Clone")
        ],
        workspace: fixture.workspace
    )
    let jobID = try #require(started.object?["jobID"]?.string)
    let result = try await waitForJob(service, jobID)
    let path = try #require(result?.object?["path"]?.string)
    let clone = URL(fileURLWithPath: path)
    #expect(try fixture.storedName(at: clone) == "Clone")
    #expect(fixture.registryPaths().contains { $0.path == clone.path })
    #expect(fixture.registryPaths().count == 2)
}

@Test @MainActor func moveRewritesTheRegistryAndRemovesTheSource() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let destination = fixture.root.appendingPathComponent("Moved")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let service = lifecycleService()
    let started = try await service.bottleCall(
        "bottle.move",
        params: [
            "container": .string(fixture.container.path),
            "destination": .string(destination.path)
        ],
        workspace: fixture.workspace
    )
    let jobID = try #require(started.object?["jobID"]?.string)
    _ = try await waitForJob(service, jobID)
    let moved = destination.appendingPathComponent(fixture.container.lastPathComponent)
    #expect(FileManager.default.fileExists(atPath: moved.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.container.path))
    #expect(fixture.registryPaths().contains { $0.path == moved.path })
}

@Test @MainActor func scannedRootMovesToAnotherBottle() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("whisky-root-move-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Source")
    let target = root.appendingPathComponent("Target")
    for bottle in [source, target] {
        try FileManager.default.createDirectory(
            at: bottle.appendingPathComponent("drive_c/Games/Touhou"),
            withIntermediateDirectories: true
        )
        try LifecycleFixture.writeMetadata(to: bottle, name: bottle.lastPathComponent)
    }
    try Data([0x4D, 0x5A]).write(to: source.appendingPathComponent("drive_c/Games/Touhou/TH06.EXE"))

    var library = FolderGameLibrary()
    library.roots = ["drive_c/Games"]
    library.knownFolders = ["drive_c/Games/Touhou"]
    try library.save(bottleURL: source)
    try FolderGameLibrary().save(bottleURL: target)

    let service = lifecycleService()
    let workspace = ApplicationWorkspace(containers: [source, target])
    _ = try await service.foldersMoveRoot(
        params: [
            "container": .string(source.path),
            "path": .string(source.appendingPathComponent("drive_c/Games").path),
            "targetContainer": .string(target.path)
        ],
        workspace: workspace
    )

    let moved = try FolderGameLibrary.load(bottleURL: target)
    let remaining = try FolderGameLibrary.load(bottleURL: source)
    // The root lives inside the source prefix, so it becomes an absolute key
    // in the target bottle without moving any files.
    let expectedRoot = source.appendingPathComponent("drive_c/Games").standardizedFileURL.path
    #expect(remaining.roots.isEmpty)
    #expect(moved.roots == [expectedRoot])
    #expect(moved.knownFolders.contains(
        source.appendingPathComponent("drive_c/Games/Touhou").standardizedFileURL.path
    ))
}

@Test @MainActor func removeDeletesFilesAndDeregisters() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.remove() }
    let service = lifecycleService()
    let started = try await service.bottleCall(
        "bottle.remove",
        params: [
            "container": .string(fixture.container.path),
            "deleteFiles": .bool(true),
            "stopProcesses": .bool(false)
        ],
        workspace: fixture.workspace
    )
    let jobID = try #require(started.object?["jobID"]?.string)
    _ = try await waitForJob(service, jobID)
    #expect(!FileManager.default.fileExists(atPath: fixture.container.path))
    #expect(fixture.registryPaths().isEmpty)
}
