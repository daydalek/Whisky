//
//  AudioRegistrySyncTests.swift
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

/// Covers the marker bookkeeping around ``Wine/syncAudioRegistry(bottle:)``.
/// The registry-writing path itself spawns wineserver and is deliberately
/// not exercised, same policy as the restart-wineserver fix.
@Suite("Audio Registry Sync Tests")
struct AudioRegistrySyncTests {
    private func makeBottleDir() -> (url: URL, cleanup: () -> Void) {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return (tempDir, { try? FileManager.default.removeItem(at: tempDir) })
    }

    @Test("Marker round-trips through the plist")
    func markerRoundTrips() throws {
        let (dir, cleanup) = makeBottleDir()
        defer { cleanup() }

        let state = AudioRegistryState(driver: "coreaudio", helBuflen: 131_072)
        try state.save(to: dir)

        #expect(AudioRegistryState.load(from: dir) == state)
    }

    @Test("A missing or corrupt marker loads as nil")
    func missingOrCorruptMarkerIsNil() throws {
        let (dir, cleanup) = makeBottleDir()
        defer { cleanup() }

        #expect(AudioRegistryState.load(from: dir) == nil)

        try Data("not a plist".utf8).write(to: AudioRegistryState.markerURL(in: dir))
        #expect(AudioRegistryState.load(from: dir) == nil)
    }

    @Test("Desired state mirrors the bottle's audio settings")
    @MainActor
    func desiredMirrorsSettings() {
        let (dir, cleanup) = makeBottleDir()
        defer { cleanup() }

        let bottle = Bottle(bottleUrl: dir, inFlight: false, isAvailable: true)
        bottle.settings.audioDriver = .coreaudio
        bottle.settings.audioLatencyPreset = .stable

        let desired = AudioRegistryState.desired(for: bottle)
        #expect(desired.driver == "coreaudio")
        #expect(desired.helBuflen == AudioLatencyPreset.stable.helBuflenValue)
    }

    @Test("Factory settings stamp the marker without booting wineserver")
    @MainActor
    func factoryDefaultsStampWithoutWine() async {
        let (dir, cleanup) = makeBottleDir()
        defer { cleanup() }

        let bottle = Bottle(bottleUrl: dir, inFlight: false, isAvailable: true)
        await Wine.syncAudioRegistry(bottle: bottle)

        #expect(AudioRegistryState.load(from: dir) == .factoryDefault)
    }

    @Test("A marker matching the settings makes sync a no-op")
    @MainActor
    func matchingMarkerIsNoOp() async throws {
        let (dir, cleanup) = makeBottleDir()
        defer { cleanup() }

        let bottle = Bottle(bottleUrl: dir, inFlight: false, isAvailable: true)
        bottle.settings.audioDriver = .coreaudio
        try AudioRegistryState.desired(for: bottle).save(to: dir)
        let before = try Data(contentsOf: AudioRegistryState.markerURL(in: dir))

        await Wine.syncAudioRegistry(bottle: bottle)

        let after = try Data(contentsOf: AudioRegistryState.markerURL(in: dir))
        #expect(before == after)
    }

    // MARK: - Reset Audio State & Two-Stage Termination Tests

    private final class AsyncWineserverRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var args: [[String]] = []
        private var bottles: [Bottle] = []

        func record(args: [String], bottle: Bottle) {
            lock.lock()
            defer { lock.unlock() }
            self.args.append(args)
            self.bottles.append(bottle)
        }

        var recordedArgs: [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return args
        }

        var recordedBottles: [Bottle] {
            lock.lock()
            defer { lock.unlock() }
            return bottles
        }
    }

    @Test("resetAudioState executes two-stage wineserver termination (-k then -w) and stamps factoryDefault")
    @MainActor
    func resetAudioStateTwoStageTerminationAndMarkerStamp() async throws {
        let (dir, cleanup) = makeBottleDir()
        defer { cleanup() }

        let bottle = Bottle(bottleUrl: dir, inFlight: false, isAvailable: true)

        // 1. Pre-condition: establish custom non-default state marker
        let customState = AudioRegistryState(driver: "coreaudio", helBuflen: 131_072)
        try customState.save(to: dir)
        #expect(AudioRegistryState.load(from: dir) == customState)

        let recorder = AsyncWineserverRecorder()

        await Wine.$wineserverAsyncRunner.withValue({ args, bottle in
            recorder.record(args: args, bottle: bottle)
            return ""
        }) {
            try? await Wine.resetAudioState(bottle: bottle)
        }

        // 2. Verify two-stage wineserver termination: ["-k"] followed immediately by ["-w"]
        #expect(recorder.recordedArgs.count == 2, "Expected exactly two wineserver invocations")
        #expect(recorder.recordedArgs.first == ["-k"], "First wineserver call must be -k (kill signal)")
        #expect(recorder.recordedArgs.last == ["-w"], "Second wineserver call must be -w (wait for exit)")
        #expect(recorder.recordedBottles.first?.url == dir, "Wineserver call must target the bottle directory")

        // 3. Verify marker was stamped to factoryDefault
        #expect(AudioRegistryState.load(from: dir) == .factoryDefault, "Audio registry state marker must be factoryDefault")
    }

    @Test("Subsequent syncAudioRegistry detects divergence and re-applies settings after resetAudioState")
    @MainActor
    func syncAudioRegistryDetectsDivergenceAfterReset() async throws {
        let (dir, cleanup) = makeBottleDir()
        defer { cleanup() }

        let bottle = Bottle(bottleUrl: dir, inFlight: false, isAvailable: true)
        bottle.settings.audioDriver = .coreaudio

        // Simulate reset stamping factoryDefault
        await Wine.$wineserverAsyncRunner.withValue({ _, _ in "" }) {
            try? await Wine.resetAudioState(bottle: bottle)
        }
        #expect(AudioRegistryState.load(from: dir) == .factoryDefault)

        // Verify that desired settings (.coreaudio) diverge from applied (.factoryDefault)
        let desired = AudioRegistryState.desired(for: bottle)
        let applied = AudioRegistryState.load(from: dir)
        #expect(desired != applied, "Desired settings must diverge from factoryDefault so sync applies them on launch")
    }
}
