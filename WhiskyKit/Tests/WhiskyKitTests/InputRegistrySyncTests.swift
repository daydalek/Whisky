//
//  InputRegistrySyncTests.swift
//  WhiskyKitTests
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
@testable import WhiskyKit

@Suite("Input Registry Sync Tests")
struct InputRegistrySyncTests {
    private func makeBottleDir() -> (url: URL, cleanup: () -> Void) {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return (tempDir, { try? FileManager.default.removeItem(at: tempDir) })
    }

    @Test("InputRegistryState marker round-trips through plist")
    func markerRoundTrips() throws {
        let (dir, cleanup) = makeBottleDir()
        defer { cleanup() }

        let state = InputRegistryState(commandActsAsControl: true)
        try state.save(to: dir)

        #expect(InputRegistryState.load(from: dir) == state)
    }

    @Test("Corrupt input marker loads as nil")
    func corruptMarkerIsNil() throws {
        let (dir, cleanup) = makeBottleDir()
        defer { cleanup() }

        try Data("corrupt payload".utf8).write(to: InputRegistryState.markerURL(in: dir))
        #expect(InputRegistryState.load(from: dir) == nil)
    }

    @Test("Desired state mirrors bottle settings commandActsAsControl")
    @MainActor
    func desiredMirrorsSettings() {
        let (dir, cleanup) = makeBottleDir()
        defer { cleanup() }

        let bottle = Bottle(bottleUrl: dir, inFlight: false, isAvailable: true, cleanInvalidPins: false)
        bottle.settings.commandActsAsControl = true

        let desired = InputRegistryState.desired(for: bottle)
        #expect(desired.commandActsAsControl == true)
    }

    @Test("Factory settings stamp input marker without running Wine")
    @MainActor
    func factoryDefaultsStampWithoutWine() async {
        let (dir, cleanup) = makeBottleDir()
        defer { cleanup() }

        let bottle = Bottle(bottleUrl: dir, inFlight: false, isAvailable: true, cleanInvalidPins: false)
        await Wine.syncInputRegistry(bottle: bottle)

        #expect(InputRegistryState.load(from: dir) == .factoryDefault)
    }

    @Test("Matching input marker makes sync a no-op")
    @MainActor
    func matchingMarkerIsNoOp() async throws {
        let (dir, cleanup) = makeBottleDir()
        defer { cleanup() }

        let bottle = Bottle(bottleUrl: dir, inFlight: false, isAvailable: true, cleanInvalidPins: false)
        bottle.settings.commandActsAsControl = true
        try InputRegistryState.desired(for: bottle).save(to: dir)
        let before = try Data(contentsOf: InputRegistryState.markerURL(in: dir))

        await Wine.syncInputRegistry(bottle: bottle)

        let after = try Data(contentsOf: InputRegistryState.markerURL(in: dir))
        #expect(before == after)
    }
}
