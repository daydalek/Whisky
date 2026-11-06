//
//  EffectiveBackendTests.swift
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

/// Pins the shared prediction: the backend a launch reply names must be the
/// backend `Wine.prepareProgramLaunch` resolves, through overrides, launcher
/// steering and payload fallback alike.
@Suite("Effective Backend Tests")
@MainActor
struct EffectiveBackendTests {
    private let tempRoot: URL

    init() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appending(path: "effectivebackend_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    private func makeBottle(backend: GraphicsBackend = .recommended) throws -> Bottle {
        let bottleURL = tempRoot.appending(path: "bottle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: bottleURL.appending(path: "drive_c"), withIntermediateDirectories: true
        )
        let bottle = Bottle(bottleUrl: bottleURL)
        bottle.settings.graphicsBackend = backend
        return bottle
    }

    private func makeExecutable(_ relativePath: String, in bottle: Bottle) throws -> URL {
        let url = bottle.url.appending(path: "drive_c").appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("MZ".utf8).write(to: url)
        return url
    }

    private func tune(_ overrides: ProgramOverrides, on url: URL, in bottle: Bottle) {
        Program(url: url, bottle: bottle, peFile: nil).settings.overrides = overrides
        // persistedOverrides flushes this write when the prediction reads it.
    }

    private func programEntry(
        _ url: URL, bottle: Bottle, launcher: LauncherType? = nil
    ) -> LibraryEntry {
        LibraryEntry(
            id: "pinned:\(url.path)", name: url.deletingPathExtension().lastPathComponent,
            iconURL: url, bottleURL: bottle.url,
            source: .pinned, launch: .program(url), launcher: launcher
        )
    }

    private func steamEntry(appId: Int, bottle: Bottle) -> LibraryEntry {
        LibraryEntry(
            id: "steam:\(appId)", name: "Game \(appId)", iconURL: nil, bottleURL: bottle.url,
            source: .steam, launch: .steam(appID: appId)
        )
    }

    /// A bottle holding a Steam install of `appId` with `executables`
    /// (install-relative paths) inside its install folder.
    private func makeGameInstall(
        appId: Int, in bottle: Bottle, executables: [String]
    ) throws -> URL {
        let steamRoot = bottle.url.appending(path: "drive_c")
            .appending(path: "Program Files (x86)").appending(path: "Steam")
        let steamApps = steamRoot.appending(path: "steamapps")
        let installURL = steamApps.appending(path: "common").appending(path: "Game\(appId)")
        try FileManager.default.createDirectory(at: installURL, withIntermediateDirectories: true)
        try Data().write(to: steamRoot.appending(path: "steam.exe"))
        for relative in executables {
            let url = installURL.appending(path: relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data().write(to: url)
        }
        let manifest = """
        "AppState"
        {
            "appid"        "\(appId)"
            "name"        "Game \(appId)"
            "installdir"        "Game\(appId)"
            "StateFlags"        "4"
        }
        """
        try Data(manifest.utf8).write(to: steamApps.appending(path: "appmanifest_\(appId).acf"))
        return installURL
    }

    // MARK: resolve

    @Test("An explicit choice stands as configured")
    func explicitChoiceStands() {
        #expect(
            EffectiveBackend.resolve(.dxvk, recommendedBackend: .dxmt, d3dMetalDeployed: false)
                == .dxvk
        )
        #expect(
            EffectiveBackend.resolve(.wined3d, recommendedBackend: .dxmt, d3dMetalDeployed: true)
                == .wined3d
        )
    }

    @Test("Recommended resolves to the runtime's recommended backend")
    func recommendedResolves() {
        #expect(
            EffectiveBackend.resolve(
                .recommended, recommendedBackend: .dxmt, d3dMetalDeployed: false
            ) == .dxmt
        )
    }

    @Test("A launcher launch steers recommended to DXVK")
    func launcherSteersRecommended() {
        #expect(
            EffectiveBackend.resolve(
                .recommended, steeredLauncher: .steam,
                recommendedBackend: .dxmt, d3dMetalDeployed: true
            ) == .dxvk
        )
        // Steering only touches recommended: an explicit choice is honored.
        #expect(
            EffectiveBackend.resolve(
                .dxmt, steeredLauncher: .steam,
                recommendedBackend: .dxmt, d3dMetalDeployed: true
            ) == .dxmt
        )
    }

    @Test("D3DMetal falls back to WineD3D when the payload is not deployed")
    func d3dMetalWithoutPayloadFallsBack() {
        let fellBack = EffectiveBackend.resolveDetailed(.d3dMetal, d3dMetalDeployed: false)
        #expect(fellBack.backend == .wined3d)
        // The fallback is reported: a UI can explain why the effective
        // backend is not the configured one.
        #expect(fellBack.unavailable == .d3dMetal)
        #expect(
            EffectiveBackend.resolve(.d3dMetal, d3dMetalDeployed: true) == .d3dMetal
        )
        // A partially deployed payload resolves recommended to D3DMetal but
        // cannot run it: the launch runs wined3d, so the answer is wined3d.
        let resolved = EffectiveBackend.resolveDetailed(
            .recommended, recommendedBackend: .d3dMetal, d3dMetalDeployed: false
        )
        #expect(resolved.backend == .wined3d)
        #expect(resolved.unavailable == .d3dMetal)
        // Steering and recommended resolution are not fallbacks.
        #expect(
            EffectiveBackend.resolveDetailed(
                .recommended, steeredLauncher: .steam,
                recommendedBackend: .d3dMetal, d3dMetalDeployed: false
            ).unavailable == nil
        )
    }

    // MARK: forProgram

    @Test("A program's own overrides beat the bottle's setting")
    func programOverridesBeatBottle() throws {
        let bottle = try makeBottle(backend: .dxvk)
        let exe = try makeExecutable("Game/Game.exe", in: bottle)
        var overrides = ProgramOverrides()
        overrides.graphicsBackend = .wined3d
        tune(overrides, on: exe, in: bottle)

        let resolution = EffectiveBackend.forProgram(
            executable: exe, bottle: bottle,
            recommendedBackend: .dxmt, d3dMetalDeployed: false
        )
        #expect(resolution.backend == .wined3d)
        #expect(resolution.unavailable == nil)
    }

    @Test("An executable detected as a launcher resolves DXVK")
    func launcherExecutableSteers() throws {
        let bottle = try makeBottle()
        let steam = try makeExecutable(
            "Program Files (x86)/Steam/steam.exe", in: bottle
        )
        #expect(
            EffectiveBackend.forProgram(
                executable: steam, bottle: bottle,
                recommendedBackend: .d3dMetal, d3dMetalDeployed: true
            ).backend == .dxvk
        )
    }

    @Test("A bottle configured for D3DMetal reports WineD3D while the payload is absent")
    func d3dMetalBottleReportsFallback() throws {
        let bottle = try makeBottle(backend: .d3dMetal)
        let exe = try makeExecutable("Game/Game.exe", in: bottle)
        #expect(
            EffectiveBackend.forProgram(
                executable: exe, bottle: bottle,
                recommendedBackend: .d3dMetal, d3dMetalDeployed: false
            ).backend == .wined3d
        )
        #expect(
            EffectiveBackend.forProgram(
                executable: exe, bottle: bottle,
                recommendedBackend: .d3dMetal, d3dMetalDeployed: false
            ).unavailable == .d3dMetal
        )
    }

    // MARK: forLaunch — program entries

    @Test("A pinned entry predicts like its program launch")
    func pinnedEntryPredicts() throws {
        let bottle = try makeBottle()
        let exe = try makeExecutable("Game/Game.exe", in: bottle)
        var overrides = ProgramOverrides()
        overrides.graphicsBackend = .dxvk
        tune(overrides, on: exe, in: bottle)

        let entry = programEntry(exe, bottle: bottle)
        #expect(
            EffectiveBackend.forLaunch(
                of: entry, executable: nil, bottle: bottle,
                recommendedBackend: .dxmt, d3dMetalDeployed: false
            )?.backend == .dxvk
        )
    }

    @Test("An explicit executable replaces the entry's own target")
    func explicitExecutableReplacesTarget() throws {
        let bottle = try makeBottle()
        let entryTarget = try makeExecutable("Game/Game.exe", in: bottle)
        let launcherExe = try makeExecutable(
            "Program Files (x86)/Steam/steam.exe", in: bottle
        )
        let entry = programEntry(entryTarget, bottle: bottle)
        // `runtime.launch` may hand a different executable (a folder game's
        // recorded one, a chooser's pick): that path is the one resolved.
        #expect(
            EffectiveBackend.forLaunch(
                of: entry, executable: launcherExe, bottle: bottle,
                recommendedBackend: .d3dMetal, d3dMetalDeployed: true
            )?.backend == .dxvk
        )
    }

    // MARK: forLaunch — folder entries

    @Test("A folder entry predicts the recorded executable's backend")
    func folderEntryUsesRecordedExecutable() throws {
        let bottle = try makeBottle(backend: .dxvk)
        let folder = bottle.url.appending(path: "drive_c").appending(path: "Games/MyGame")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let exe = folder.appending(path: "bin/Game.exe")
        try FileManager.default.createDirectory(
            at: exe.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("MZ".utf8).write(to: exe)

        var library = FolderGameLibrary()
        library.executables[FolderGameLibrary.key(for: folder, bottleURL: bottle.url)] =
            FolderGameLibrary.key(for: exe, bottleURL: bottle.url)
        try library.save(bottleURL: bottle.url)

        var overrides = ProgramOverrides()
        overrides.graphicsBackend = .wined3d
        tune(overrides, on: exe, in: bottle)

        let entry = LibraryEntry(
            id: "folder:test", name: "MyGame", iconURL: exe, bottleURL: bottle.url,
            source: .folder, launch: .program(folder)
        )
        #expect(
            EffectiveBackend.forLaunch(
                of: entry, executable: nil, bottle: bottle,
                recommendedBackend: .dxmt, d3dMetalDeployed: false
            )?.backend == .wined3d
        )
    }

    @Test("A folder entry with no usable recording has nothing to name")
    func folderEntryWithoutRecording() throws {
        let bottle = try makeBottle()
        let folder = bottle.url.appending(path: "drive_c").appending(path: "Games/Empty")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let entry = LibraryEntry(
            id: "folder:test", name: "Empty", iconURL: nil, bottleURL: bottle.url,
            source: .folder, launch: .program(folder)
        )
        #expect(
            EffectiveBackend.forLaunch(
                of: entry, executable: nil, bottle: bottle,
                recommendedBackend: .dxmt, d3dMetalDeployed: false
            ) == nil
        )
    }

    // MARK: forLaunch — Steam entries

    @Test("A Steam entry resolves the selected program's overrides, not steam.exe's DXVK")
    func steamEntryUsesGamePlan() throws {
        let bottle = try makeBottle(backend: .dxvk)
        let installURL = try makeGameInstall(
            appId: 1_234_560, in: bottle, executables: ["Game.exe", "bin/Helper.exe"]
        )
        let gameExe = installURL.appending(path: "Game.exe")
        try SteamGameProgram.select(
            gameExe, appID: 1_234_560, installURL: installURL, bottleURL: bottle.url
        )
        var overrides = ProgramOverrides()
        overrides.graphicsBackend = .dxmt
        tune(overrides, on: gameExe, in: bottle)

        // The old answer named steam.exe's DXVK; the launch runs the plan's
        // overrides on the game's own processes, so the plan decides.
        #expect(
            EffectiveBackend.forLaunch(
                of: steamEntry(appId: 1_234_560, bottle: bottle), executable: nil, bottle: bottle,
                recommendedBackend: .dxvk, d3dMetalDeployed: false
            )?.backend == .dxmt
        )
    }

    @Test("An untuned Steam entry resolves the bottle's backend unsteered")
    func steamEntryDefaultsToBottle() throws {
        let bottle = try makeBottle()
        _ = try makeGameInstall(appId: 6_543_210, in: bottle, executables: ["Game.exe"])
        #expect(
            EffectiveBackend.forLaunch(
                of: steamEntry(appId: 6_543_210, bottle: bottle), executable: nil, bottle: bottle,
                recommendedBackend: .d3dMetal, d3dMetalDeployed: true
            )?.backend == .d3dMetal
        )
    }

    @Test("A Steam entry on an absent install falls back to the bottle")
    func steamEntryWithoutInstall() throws {
        let bottle = try makeBottle(backend: .wined3d)
        #expect(
            EffectiveBackend.forLaunch(
                of: steamEntry(appId: 9_999_999, bottle: bottle), executable: nil, bottle: bottle,
                recommendedBackend: .dxvk, d3dMetalDeployed: false
            )?.backend == .wined3d
        )
    }
}
