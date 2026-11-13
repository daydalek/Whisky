//
//  WineEngineIntegrationTests.swift
//  WhiskyKit
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

/// Two bottles bound to two different external engines: every bottle-bound
/// Wine path must follow the bottle's own engine snapshot — loader, server,
/// library and feature policy — with no cross-engine leakage and no silent
/// managed fallback.
@Suite("Selected-engine launch integration")
@MainActor struct WineEngineIntegrationTests {
    private func temporaryRoot(_ label: String = "integration") throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisky-\(label)-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func copyBinary(_ name: String, to url: URL) throws {
        try FileManager.default.copyItem(at: URL(fileURLWithPath: name), to: url)
    }

    /// A bare standard engine: real Mach-O `wine64` + `wineserver` + `lib/`.
    private func makeEngine(at root: URL, dxvk: Bool = false) throws {
        let bin = root.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appending(path: "lib"), withIntermediateDirectories: true
        )
        try copyBinary("/usr/bin/true", to: bin.appending(path: "wine64"))
        try copyBinary("/usr/bin/false", to: bin.appending(path: "wineserver"))
        if dxvk {
            // Complete payload: the preset's DLL set in both tiers, each a
            // fake PE binary (MZ magic, no builtin marker at 0x40). No
            // dxgi.dll — DXVK-macOS ships none and the launcher reconciles
            // the runtime builtin instead.
            for arch in ["x64", "x32"] {
                for name in ["d3d9", "d3d10core", "d3d11"] {
                    let dll = root.appending(path: "DXVK/\(arch)/\(name).dll")
                    try FileManager.default.createDirectory(
                        at: dll.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    var data = Data(repeating: 0, count: 0x60)
                    data[0] = 0x4D
                    data[1] = 0x5A
                    try data.write(to: dll)
                }
            }
        }
    }

    private func makeBottle(in root: URL, name: String) throws -> Bottle {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(
            at: url.appending(path: "drive_c/windows/system32"), withIntermediateDirectories: true
        )
        let bottle = Bottle(bottleUrl: url, inFlight: false, isAvailable: true)
        bottle.settings.name = name
        return bottle
    }

    private func withStore<T>(
        _ store: WineEngineStore, _ body: () throws -> T
    ) rethrows -> T {
        try Wine.$engineStoreOverride.withValue(store, operation: body)
    }

    // MARK: - Engine-bound runtime paths

    @Test func twoBottlesResolveTheirOwnLoaderServerAndLibrary() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WineEngineStore(registryURL: root.appending(path: "engines.json")) { [] }
        try makeEngine(at: root.appending(path: "engineA"))
        try makeEngine(at: root.appending(path: "engineB"))
        let engineA = try store.register(at: root.appending(path: "engineA"), name: "A")
        let engineB = try store.register(at: root.appending(path: "engineB"), name: "B")

        let bottleA = try makeBottle(in: root, name: "BottleA")
        bottleA.settings.wineEngineID = engineA.id
        let bottleB = try makeBottle(in: root, name: "BottleB")
        bottleB.settings.wineEngineID = engineB.id

        let envA = try withStore(store) {
            try Wine.constructWineEnvironment(for: bottleA)
        }
        let envB = try withStore(store) {
            try Wine.constructWineEnvironment(for: bottleB)
        }

        // Each bottle's base paths point at its own engine, never the other's
        // and never the managed tree.
        #expect(envA["WINELOADER"] == engineA.wineBinary.path)
        #expect(envA["WINESERVER"] == engineA.wineserverBinary.path)
        #expect(envA["DYLD_FALLBACK_LIBRARY_PATH"]?.contains(engineA.libraryURL.path) == true)
        #expect(envB["WINELOADER"] == engineB.wineBinary.path)
        #expect(envB["WINESERVER"] == engineB.wineserverBinary.path)
        #expect(envB["DYLD_FALLBACK_LIBRARY_PATH"]?.contains(engineB.libraryURL.path) == true)
        #expect(envA["WINELOADER"] != envB["WINELOADER"])
        let managedLoader = WhiskyWineInstaller.binFolder.appending(path: "wine64").path
        #expect(envA["WINELOADER"] != managedLoader)
        #expect(envB["WINELOADER"] != managedLoader)
    }

    @Test func generatedCommandRunsTheSelectedEngineLoader() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WineEngineStore(registryURL: root.appending(path: "engines.json")) { [] }
        try makeEngine(at: root.appending(path: "engineA"))
        let engineA = try store.register(at: root.appending(path: "engineA"), name: "A")
        let bottle = try makeBottle(in: root, name: "Bottle")
        bottle.settings.wineEngineID = engineA.id

        let command = try withStore(store) {
            try Wine.generateRunCommand(
                at: URL(fileURLWithPath: "/tmp/Game.exe"), bottle: bottle,
                args: "", environment: [:]
            )
        }
        #expect(command.contains(engineA.wineBinary.path))
        #expect(!command.contains(WhiskyWineInstaller.binFolder.appending(path: "wine64").path))
    }

    @Test func missingEngineThrowsInsteadOfFallingBackToManaged() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WineEngineStore(registryURL: root.appending(path: "engines.json")) { [] }
        let bottle = try makeBottle(in: root, name: "Bottle")
        bottle.settings.wineEngineID = "ghost-engine"

        #expect(throws: WineEngineError.self) {
            try withStore(store) { try Wine.constructWineEnvironment(for: bottle) }
        }
        #expect(throws: WineEngineError.self) {
            try withStore(store) { try Wine.engine(for: bottle) }
        }
    }

    // MARK: - Backend policy

    @Test func externalRecommendedIsWineD3DWithoutConfirmedCapabilities() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WineEngineStore(registryURL: root.appending(path: "engines.json")) { [] }
        try makeEngine(at: root.appending(path: "bare"))
        let bare = try store.register(at: root.appending(path: "bare"))

        #expect(Wine.recommendedBackend(for: bare, overrides: [:]) == .wined3d)
        // Even a saved DXVK choice cannot promote the recommendation: no
        // payload, no confirmation.
        let stale = ["dxvk": "other-fingerprint"]
        #expect(Wine.recommendedBackend(for: bare, overrides: stale) == .wined3d)
    }

    @Test func externalRecommendedFollowsDetectedPayload() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WineEngineStore(registryURL: root.appending(path: "engines.json")) { [] }
        try makeEngine(at: root.appending(path: "withdxvk"), dxvk: true)
        let engine = try store.register(at: root.appending(path: "withdxvk"))

        // A complete payload is still only *unverified* on an external
        // engine — the recommendation stays on base WineD3D until the user
        // confirms, then the confirmed capability drives it.
        #expect(engine.status(of: .dxvk).state == .unverified)
        #expect(Wine.recommendedBackend(for: engine, overrides: [:]) == .wined3d)
        let approved = ["dxvk": engine.fingerprint]
        #expect(Wine.recommendedBackend(for: engine, overrides: approved) == .dxvk)
    }

    @Test func savedDXVKChoiceDoesNotInjectDLLsWithoutPayload() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WineEngineStore(registryURL: root.appending(path: "engines.json")) { [] }
        try makeEngine(at: root.appending(path: "bare"))
        let engine = try store.register(at: root.appending(path: "bare"))
        let bottle = try makeBottle(in: root, name: "Bottle")
        bottle.settings.wineEngineID = engine.id
        // The bottle still records the user's choice — the runtime must gate
        // it, not rewrite the setting.
        bottle.settings.graphicsBackend = .dxvk

        let env = try withStore(store) {
            try Wine.constructWineEnvironment(for: bottle)
        }
        #expect(bottle.settings.graphicsBackend == .dxvk)
        #expect(env["WINEDLLOVERRIDES"]?.contains("d3d11=n") != true)
        #expect(env["DXVK_HUD"] == nil)
        #expect(env["DXVK_ASYNC"] == nil)
    }

    @Test func launcherDXVKRequirementIsGatedOnExternalEngine() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WineEngineStore(registryURL: root.appending(path: "engines.json")) { [] }
        try makeEngine(at: root.appending(path: "bare"))
        let engine = try store.register(at: root.appending(path: "bare"))
        let bottle = try makeBottle(in: root, name: "Bottle")
        bottle.settings.wineEngineID = engine.id
        // Rockstar requires DXVK on managed; on this payload-less external
        // engine the launcher's own steering must not sneak the DLL set in.
        bottle.settings.detectedLauncher = .rockstar

        let env = try withStore(store) {
            try Wine.constructWineEnvironment(for: bottle)
        }
        #expect(env["WINEDLLOVERRIDES"]?.contains("d3d11=n") != true)
    }

    @Test func detectedDXVKPayloadStillAppliesOnExternal() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WineEngineStore(registryURL: root.appending(path: "engines.json")) { [] }
        try makeEngine(at: root.appending(path: "withdxvk"), dxvk: true)
        let engine = try store.register(at: root.appending(path: "withdxvk"))
        let bottle = try makeBottle(in: root, name: "Bottle")
        bottle.settings.wineEngineID = engine.id
        bottle.settings.graphicsBackend = .dxvk

        // The payload is unverified, so the saved choice alone injects
        // nothing; once the user confirms against the current fingerprint,
        // the same choice takes effect.
        let gated = try withStore(store) {
            try Wine.constructWineEnvironment(for: bottle)
        }
        #expect(gated["WINEDLLOVERRIDES"]?.contains("d3d11=n") != true)

        bottle.settings.wineFeatureOverrides = ["dxvk": engine.fingerprint]
        let env = try withStore(store) {
            try Wine.constructWineEnvironment(for: bottle)
        }
        #expect(env["WINEDLLOVERRIDES"]?.contains("d3d11=n") == true)
    }

    // MARK: - Final external env policy

    /// Every layer — user vars, game profiles, program env — could repoint
    /// the launch at a different prefix or splice another runtime's search
    /// paths in. The final pass reasserts the selected engine's identity.
    @Test func userLayersCannotRedirectPrefixLoaderOrLibraries() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WineEngineStore(registryURL: root.appending(path: "engines.json")) { [] }
        try makeEngine(at: root.appending(path: "bare"))
        let engine = try store.register(at: root.appending(path: "bare"))
        let bottle = try makeBottle(in: root, name: "Bottle")
        bottle.settings.wineEngineID = engine.id
        bottle.settings.userEnvironment = ["PROFILE_PREFIX": "untouched"]

        let hostile: [String: String] = [
            "WINEPREFIX": "/tmp/another-prefix",
            "WINELOADER": "/tmp/other/bin/wine64",
            "WINESERVER": "/tmp/other/bin/wineserver",
            "DYLD_LIBRARY_PATH": "/tmp/other/lib",
            "DYLD_FRAMEWORK_PATH": "/tmp/other/frameworks",
            "DYLD_FALLBACK_FRAMEWORK_PATH": "/tmp/other/fallback-fw",
            "DYLD_INSERT_LIBRARIES": "/tmp/other/inject.dylib",
            "WINEDLLPATH": "/tmp/other/dlls",
            "DYLD_FALLBACK_LIBRARY_PATH": "/tmp/other/fallback",
            "WINE_GDI_UPSCALER": "fsr",
            "UNRELATED_FLAG": "keep-me"
        ]
        let env = try withStore(store) {
            try Wine.constructWineEnvironment(
                for: bottle, environment: hostile,
                gameProfileEnvironment: ["WINEPREFIX": "/tmp/profile-prefix"]
            )
        }
        #expect(env["WINEPREFIX"] == bottle.url.path(percentEncoded: false))
        #expect(env["WINELOADER"] == engine.wineBinary.path(percentEncoded: false))
        #expect(env["WINESERVER"] == engine.wineserverBinary.path(percentEncoded: false))
        #expect(env["DYLD_FALLBACK_LIBRARY_PATH"] ==
            "\(engine.libraryURL.path(percentEncoded: false)):/usr/lib")
        for key in [
            "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH", "DYLD_FALLBACK_FRAMEWORK_PATH",
            "DYLD_INSERT_LIBRARIES", "WINEDLLPATH", "WINE_GDI_UPSCALER"
        ] {
            #expect(env[key] == nil, "\(key) must be stripped on an external engine")
        }
        #expect(env["UNRELATED_FLAG"] == "keep-me")
        #expect(env["PROFILE_PREFIX"] == "untouched")
    }

    /// A user-set custom override — or a raw `WINEDLLOVERRIDES` env vote —
    /// naming a native translation DLL must not resurrect it on an
    /// unapproved engine; unrelated names pass through verbatim.
    @Test func customLayersCannotReenableUnapprovedTranslationDLLs() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WineEngineStore(registryURL: root.appending(path: "engines.json")) { [] }
        try makeEngine(at: root.appending(path: "bare"))
        let engine = try store.register(at: root.appending(path: "bare"))
        let bottle = try makeBottle(in: root, name: "Bottle")
        bottle.settings.wineEngineID = engine.id
        bottle.settings.dllOverrides = [
            DLLOverrideEntry(dllName: "d3d11", mode: .native),
            DLLOverrideEntry(dllName: "xinput1_3", mode: .native)
        ]

        let env = try withStore(store) {
            try Wine.constructWineEnvironment(
                for: bottle,
                environment: ["WINEDLLOVERRIDES": "d3d9=n;xinput1_4=n"]
            )
        }
        let overrides = Wine.parseDLLOverrides(env["WINEDLLOVERRIDES"] ?? "")
        // Translation DLLs the unapproved backend would use are clamped to
        // builtin — user custom entries and raw env votes alike.
        #expect(overrides["d3d11"] == "b")
        #expect(overrides["d3d9"] == "b")
        #expect(overrides["dxgi"] == "b")
        // Unrelated custom names survive with their raw mode strings.
        #expect(overrides["xinput1_3"] == "n")
        #expect(overrides["xinput1_4"] == "n")
    }

    /// An approved backend keeps its own translation DLLs native; the other
    /// layer's names stay clamped even against custom entries.
    @Test func approvedDXVKKeepsItsNativesAndClampsDXMT() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WineEngineStore(registryURL: root.appending(path: "engines.json")) { [] }
        try makeEngine(at: root.appending(path: "withdxvk"), dxvk: true)
        let engine = try store.register(at: root.appending(path: "withdxvk"))
        let bottle = try makeBottle(in: root, name: "Bottle")
        bottle.settings.wineEngineID = engine.id
        bottle.settings.graphicsBackend = .dxvk
        bottle.settings.wineFeatureOverrides = ["dxvk": engine.fingerprint]
        // A stale native winemetal vote must not survive — DXMT is not
        // approved just because DXVK is.
        bottle.settings.dllOverrides = [DLLOverrideEntry(dllName: "winemetal", mode: .native)]

        let env = try withStore(store) {
            try Wine.constructWineEnvironment(for: bottle)
        }
        let overrides = Wine.parseDLLOverrides(env["WINEDLLOVERRIDES"] ?? "")
        #expect(overrides["d3d11"] == "n,b")
        #expect(overrides["d3d9"] == "n,b")
        #expect(overrides["winemetal"] == "b")
    }

    // MARK: - Feature confirmation

    @Test func savedMsyncIsGatedUntilConfirmedForCurrentFingerprint() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WineEngineStore(registryURL: root.appending(path: "engines.json")) { [] }
        try makeEngine(at: root.appending(path: "bare"))
        let engine = try store.register(at: root.appending(path: "bare"))
        let bottle = try makeBottle(in: root, name: "Bottle")
        bottle.settings.wineEngineID = engine.id
        bottle.settings.enhancedSync = .msync

        // Unverified feature, no confirmation → gated off.
        let denied = try withStore(store) {
            try Wine.constructWineEnvironment(for: bottle)
        }
        #expect(denied["WINEMSYNC"] == nil)

        // Stale fingerprint → still gated off.
        bottle.settings.wineFeatureOverrides = ["msync": "outdated-fingerprint"]
        let stale = try withStore(store) {
            try Wine.constructWineEnvironment(for: bottle)
        }
        #expect(stale["WINEMSYNC"] == nil)

        // Approval bound to the engine's current fingerprint → honored.
        bottle.settings.wineFeatureOverrides = ["msync": engine.fingerprint]
        let approved = try withStore(store) {
            try Wine.constructWineEnvironment(for: bottle)
        }
        #expect(approved["WINEMSYNC"] == "1")
    }

    @Test func approvalIsPerFeatureNotBlanket() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WineEngineStore(registryURL: root.appending(path: "engines.json")) { [] }
        try makeEngine(at: root.appending(path: "bare"))
        let engine = try store.register(at: root.appending(path: "bare"))
        let bottle = try makeBottle(in: root, name: "Bottle")
        bottle.settings.wineEngineID = engine.id
        bottle.settings.dxvkAsync = true
        bottle.settings.enhancedSync = .msync

        // Approving msync must not unlock dxvkAsync (or anything else).
        bottle.settings.wineFeatureOverrides = ["msync": engine.fingerprint]
        let env = try withStore(store) {
            try Wine.constructWineEnvironment(for: bottle)
        }
        #expect(env["WINEMSYNC"] == "1")
        #expect(env["DXVK_ASYNC"] != "1")
    }

    @Test func unavailableFeatureCannotBeApproved() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WineEngineStore(registryURL: root.appending(path: "engines.json")) { [] }
        try makeEngine(at: root.appending(path: "bare"))
        let engine = try store.register(at: root.appending(path: "bare"))
        let bottle = try makeBottle(in: root, name: "Bottle")
        bottle.settings.wineEngineID = engine.id
        bottle.settings.graphicsBackend = .dxvk

        // A forged approval for an unavailable (missing payload) feature is
        // ignored: mandatory prerequisites cannot be confirmed around.
        bottle.settings.wineFeatureOverrides = ["dxvk": engine.fingerprint]
        let env = try withStore(store) {
            try Wine.constructWineEnvironment(for: bottle)
        }
        #expect(env["WINEDLLOVERRIDES"]?.contains("d3d11=n") != true)
    }

    // MARK: - Managed compatibility

    @Test func managedEngineBehaviorIsUnchanged() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WineEngineStore(registryURL: root.appending(path: "engines.json")) { [] }
        let bottle = try makeBottle(in: root, name: "Bottle")
        // Default engine is managed; saved msync default stays honored.
        #expect(bottle.settings.wineEngineID == WineEngine.managedID)

        let env = try withStore(store) {
            try Wine.constructWineEnvironment(for: bottle)
        }
        let managed = WineEngine.managed
        #expect(env["WINELOADER"] == managed.wineBinary.path)
        #expect(env["WINESERVER"] == managed.wineserverBinary.path)
        #expect(env["WINEMSYNC"] == "1")
    }

    // MARK: - Terminal command

    @Test func terminalEnvironmentCommandUsesSelectedEngine() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WineEngineStore(registryURL: root.appending(path: "engines.json")) { [] }
        try makeEngine(at: root.appending(path: "engineA"))
        let engineA = try store.register(at: root.appending(path: "engineA"))
        let bottle = try makeBottle(in: root, name: "Bottle")
        bottle.settings.wineEngineID = engineA.id

        let command = try withStore(store) {
            try Wine.generateTerminalEnvironmentCommand(bottle: bottle)
        }
        #expect(
            command.contains(engineA.wineBinary.deletingLastPathComponent().path)
                || command.contains(engineA.libraryURL.path)
        )
        #expect(!command.contains(WhiskyWineInstaller.binFolder.path))
    }
}
