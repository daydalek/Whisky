//
//  EntryMoveTests.swift
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
@testable import WhiskyNativeBridge

private struct Fixture {
    let root: URL
    let source: URL
    let target: URL
    let executable: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("whisky-move-\(UUID())")
        source = root.appendingPathComponent("source")
        target = root.appendingPathComponent("target")
        executable = source.appendingPathComponent("drive_c/Game/game.exe")
        for (bottle, name) in [(source, "Source"), (target, "Target")] {
            try FileManager.default.createDirectory(
                at: bottle.appendingPathComponent("drive_c"),
                withIntermediateDirectories: true
            )
            try Self.writeMetadata(
                to: bottle,
                name: name,
                pins: bottle == source ? [("Game", executable)] : []
            )
        }
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x4D, 0x5A]).write(to: executable)
        // The pins encoder needs the executable to exist first.
        try Self.writeMetadata(to: source, name: "Source", pins: [("Game", executable)])
    }

    private static func writeMetadata(
        to bottle: URL,
        name: String,
        pins: [(String, URL)]
    ) throws {
        struct Pin: Encodable {
            let name: String
            let url: URL
            let removable: Bool
        }
        struct Info: Encodable {
            let name: String
            let pins: [Pin]
            let blocklist: [URL]
        }
        struct Metadata: Encodable {
            let info: Info
        }
        let value = Metadata(info: Info(
            name: name,
            pins: pins.map { Pin(name: $0.0, url: $0.1, removable: false) },
            blocklist: []
        ))
        try PropertyListEncoder().encode(value)
            .write(to: bottle.appendingPathComponent("Metadata.plist"))
    }

    var workspace: ApplicationWorkspace {
        ApplicationWorkspace(containers: [source, target])
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor private func services() -> MacOSApplicationServices {
    MacOSApplicationServices(
        wineEnabled: false,
        preferencesDomain: "com.franke.Whisky.tests.\(UUID().uuidString)",
        jobs: BridgeJobStore()
    )
}

@Test @MainActor func entryMoveTransfersPinAndRejectsSameContainer() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let service = services()
    let entryID = "pinned:\(fixture.executable.path)"
    let result = try await service.entryMove(
        [
            "container": .string(fixture.source.path),
            "entryID": .string(entryID),
            "targetContainer": .string(fixture.target.path)
        ],
        workspace: fixture.workspace
    )
    #expect(result.object?["targetContainer"] == .string(fixture.target.path))
    #expect(result.object?["entry"]?.object?["container"] == .string(fixture.target.path))
    let targetPins = try await ConfigurationFile(
        url: fixture.target.appendingPathComponent("Metadata.plist"),
        locking: HostFileLock()
    ).pinnedPrograms()
    let sourcePins = try await ConfigurationFile(
        url: fixture.source.appendingPathComponent("Metadata.plist"),
        locking: HostFileLock()
    ).pinnedPrograms()
    #expect(targetPins.map(\.url) == [fixture.executable])
    #expect(sourcePins.isEmpty)
    await #expect(throws: BridgeFailure.self) {
        _ = try await service.entryMove(
            [
                "container": .string(fixture.source.path),
                "entryID": .string(entryID),
                "targetContainer": .string(fixture.source.path)
            ],
            workspace: fixture.workspace
        )
    }
}
