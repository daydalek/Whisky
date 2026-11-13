//
//  WinetricksExecutionTests.swift
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

@Test func winetricksOutputPreservesFragmentedUnicodeAndBoundsLines() {
    let decoder = WinetricksOutputDecoder()
    var lines: [String] = []
    for byte in Data("中文 日本語\n尾部".utf8) {
        lines += decoder.append(Data([byte]))
    }
    lines += decoder.append(Data(), finish: true)
    #expect(lines == ["中文 日本語", "尾部"])
    #expect(decoder.append(Data(repeating: 65, count: 20_000)).joined().count == 20_000)
}

@Test func winetricksWaitTerminatesTimedOutAndCancelledCommands() async throws {
    for cancel in [false, true] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        let task = Task { await WinetricksService.awaitProcessCompletion(process, timeout: cancel ? 60 : 0.05) }
        if cancel {
            task.cancel()
        }
        let failure = await task.value
        #expect(failure == (cancel ? "Installation cancelled" : "Installation timed out"))
        #expect(!process.isRunning)
    }
}

@Test @MainActor func vcRedistInstalledSynchronizesFromWinetricksVerbCache() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let bottle = Bottle(bottleUrl: tempDir, inFlight: false, isAvailable: true, cleanInvalidPins: false)
    #expect(!bottle.settings.vcRedistInstalled)

    // Fresh bottle with no cache returns false
    #expect(!bottle.synchronizeVCRedistStatus())
    #expect(!bottle.settings.vcRedistInstalled)

    // Cache without VC++ runtime verbs does not mark vcRedistInstalled
    let unrelatedCache = WinetricksVerbCache(installedVerbs: ["d3dx9", "dotnet40"], lastChecked: Date())
    try WinetricksVerbCache.save(unrelatedCache, to: tempDir)
    #expect(!bottle.synchronizeVCRedistStatus())
    #expect(!bottle.settings.vcRedistInstalled)

    // Simulate winetricks verb cache with vcrun2019 installed
    let cache2019 = WinetricksVerbCache(installedVerbs: ["vcrun2019", "d3dx9"], lastChecked: Date())
    try WinetricksVerbCache.save(cache2019, to: tempDir)

    // Execute synchronization logic via production Bottle method
    let synchronized = bottle.synchronizeVCRedistStatus()
    #expect(synchronized)
    #expect(bottle.settings.vcRedistInstalled)

    // Subsequent call is idempotent
    #expect(bottle.synchronizeVCRedistStatus())

    // Verify BottleSettings direct synchronization with vcrun2022
    var testSettings = BottleSettings()
    #expect(!testSettings.vcRedistInstalled)
    let cache2022 = WinetricksVerbCache(installedVerbs: ["vcrun2022"], lastChecked: Date())
    let settingsSynchronized = testSettings.synchronizeVCRedistStatus(with: cache2022)
    #expect(settingsSynchronized)
    #expect(testSettings.vcRedistInstalled)
}

/// The winetricks process environment is the boundary every invocation —
/// install AND `list-installed` — shares: `WINE`/`WINESERVER` must name the
/// selected engine's binaries by absolute path so a `wine`-only tree (no
/// `wine64` name) works and nothing falls through to another runtime.
@Test func winetricksEnvironmentBindsSelectedEngineBinaries() {
    func externalEngine(root: URL, loader: String) -> WineEngine {
        WineEngine(
            id: root.lastPathComponent,
            name: root.lastPathComponent,
            rootURL: root,
            wineBinary: root.appendingPathComponent("bin/\(loader)"),
            wineserverBinary: root.appendingPathComponent("bin/wineserver"),
            libraryURL: root.appendingPathComponent("lib"),
            librariesURL: nil,
            isManaged: false,
            fingerprint: "fp",
            architectures: ["arm64"],
            availabilityError: nil,
            version: nil
        )
    }
    let bottleURL = URL(fileURLWithPath: "/tmp/WT Bottle")
    let resourcesURL = URL(fileURLWithPath: "/tmp/Resources")

    // A `wine`-only tree: WINE is bin/wine, never a wine64 guess.
    let wineOnly = externalEngine(
        root: URL(fileURLWithPath: "/tmp/Engines/Wine Only 引擎"), loader: "wine"
    )
    let env = WinetricksService.winetricksEnvironment(
        bottleURL: bottleURL, resourcesURL: resourcesURL, engine: wineOnly
    )
    #expect(env["WINE"] == "/tmp/Engines/Wine Only 引擎/bin/wine")
    #expect(env["WINESERVER"] == "/tmp/Engines/Wine Only 引擎/bin/wineserver")
    #expect(env["WINEPREFIX"] == "/tmp/WT Bottle")
    #expect(env["DYLD_FALLBACK_LIBRARY_PATH"] == "/tmp/Engines/Wine Only 引擎/lib:/usr/lib")
    // Engine bin leads PATH: helper tools resolve inside the same tree.
    #expect(env["PATH"]?.hasPrefix("/tmp/Engines/Wine Only 引擎/bin:") == true)

    // A second engine produces its own recipe — no cross-tree leakage.
    let other = externalEngine(root: URL(fileURLWithPath: "/tmp/Engines/Other"), loader: "wine64")
    let otherEnv = WinetricksService.winetricksEnvironment(
        bottleURL: bottleURL, resourcesURL: resourcesURL, engine: other
    )
    #expect(otherEnv["WINE"] == "/tmp/Engines/Other/bin/wine64")
    #expect(otherEnv["PATH"]?.hasPrefix("/tmp/Engines/Other/bin:") == true)
    #expect(otherEnv["WINE"] != env["WINE"])
}
