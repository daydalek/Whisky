//
//  LinuxWineEngineTests.swift
//  WhiskyBridgeTests
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
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

@Suite("Linux custom Wine engines")
struct LinuxWineEngineTests {
    private static func currentHostArchitecture() -> String {
        var name = utsname()
        guard uname(&name) == 0 else { return "x86_64" }
        let machine = withUnsafeBytes(of: &name.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine == "arm64" ? "aarch64" : machine
    }

    private static func foreignArchitecture() -> String {
        currentHostArchitecture() == "aarch64" ? "x86_64" : "aarch64"
    }

    private static func elfHeaderData(architecture: String, pie: Bool = true) -> Data {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0] = 0x7F
        bytes[1] = 0x45 // E
        bytes[2] = 0x4C // L
        bytes[3] = 0x46 // F
        bytes[4] = architecture == "i386" ? 1 : 2 // ELFCLASS32 / ELFCLASS64
        bytes[5] = 1 // little endian
        bytes[6] = 1 // EV_CURRENT
        let eType: UInt16 = pie ? 3 : 2 // ET_DYN / ET_EXEC
        bytes[16] = UInt8(eType & 0xFF)
        bytes[17] = UInt8(eType >> 8)
        let machine: UInt16 = switch architecture {
        case "aarch64": 0xB7
        case "x86_64": 0x3E
        case "i386": 0x03
        default: 0x00
        }
        bytes[18] = UInt8(machine & 0xFF)
        bytes[19] = UInt8(machine >> 8)
        return Data(bytes)
    }

    @discardableResult
    private static func makeELFEngineTree(
        at root: URL,
        loaderArch: String = currentHostArchitecture(),
        serverArch: String = currentHostArchitecture(),
        nestedWineDir: Bool = false,
        loaderName: String = "wine",
        pie: Bool = true,
        includeLib: Bool = true,
        version: String? = nil
    ) throws -> URL {
        let base = nestedWineDir ? root.appendingPathComponent("Wine", isDirectory: true) : root
        let bin = base.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        if includeLib {
            try FileManager.default.createDirectory(
                at: base.appendingPathComponent("lib", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let loader = bin.appendingPathComponent(loaderName)
        let server = bin.appendingPathComponent("wineserver")
        try elfHeaderData(architecture: loaderArch, pie: pie).write(to: loader)
        try elfHeaderData(architecture: serverArch, pie: pie).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: loader.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)
        if let version {
            let release = #"{"version":"\#(version)"}"#
            try Data(release.utf8).write(to: base.appendingPathComponent("release.json"))
        }
        return root
    }

    private static func makeContainer(root: URL, name: String) throws -> URL {
        let bottle = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: bottle.appendingPathComponent("drive_c/windows/system32", isDirectory: true),
            withIntermediateDirectories: true
        )
        let metadata: [String: Any] = [
            "info": ["name": name],
            "wineConfig": ["windowsVersion": "win10"]
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
        try plist.write(to: bottle.appendingPathComponent("Metadata.plist"), options: .atomic)
        return bottle
    }

    @Test func detectsNativeELFAndRejectsInvalidLayouts() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("linux-engine-detect-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let arm64Root = try Self.makeELFEngineTree(
            at: temp.appendingPathComponent("arm64-engine"),
            loaderArch: "aarch64",
            serverArch: "aarch64",
            pie: true,
            version: "11.0-arm64"
        )
        let detectedArm64 = try LinuxWineEngine.detect(
            id: "e1",
            name: "Proton ARM64",
            at: arm64Root,
            environment: ["PATH": "/usr/bin:/bin"]
        )
        #expect(detectedArm64.architectures == ["aarch64"])
        #expect(!detectedArm64.managed)
        #expect(detectedArm64.version == "11.0-arm64")
        #expect(detectedArm64.fingerprint != nil)
        #expect(detectedArm64.featureStatus(.esync).state == .unverified)
        #expect(detectedArm64.featureStatus(.esync).canOverride)
        #expect(detectedArm64.featureStatus(.dxvk).state == .unverified)
        #expect(detectedArm64.featureStatus(.msync).state == .unavailable)
        #expect(detectedArm64.featureStatus(.d3dMetal).state == .unavailable)

        let nestedRoot = try Self.makeELFEngineTree(
            at: temp.appendingPathComponent("nested"),
            nestedWineDir: true,
            loaderName: "wine64"
        )
        let nestedEngine = try LinuxWineEngine.detect(id: "e2", at: nestedRoot, environment: [:])
        #expect(nestedEngine.runtimeURL == nestedRoot.appendingPathComponent("Wine").resolvingSymlinksInPath())

        // Shell scripts in bin/wine must be rejected statically.
        let scriptRoot = temp.appendingPathComponent("script-engine", isDirectory: true)
        try Self.makeELFEngineTree(at: scriptRoot)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: scriptRoot.appendingPathComponent("bin/wine"))
        #expect(throws: LinuxWineEngineError.invalidBinary(scriptRoot.appendingPathComponent("bin/wine").resolvingSymlinksInPath())) {
            _ = try LinuxWineEngine.detect(id: "bad-script", at: scriptRoot)
        }

        // Cross-ISA mismatch (aarch64 loader + x86_64 wineserver) must be rejected.
        let mismatchRoot = temp.appendingPathComponent("mismatch-engine", isDirectory: true)
        try Self.makeELFEngineTree(at: mismatchRoot, loaderArch: "aarch64", serverArch: "x86_64")
        #expect(throws: LinuxWineEngineError.architectureMismatch(loader: "aarch64", wineserver: "x86_64")) {
            _ = try LinuxWineEngine.detect(id: "bad-arch", at: mismatchRoot)
        }

        // Missing lib/ must be rejected.
        let noLibRoot = temp.appendingPathComponent("no-lib-engine", isDirectory: true)
        try Self.makeELFEngineTree(at: noLibRoot, includeLib: false)
        #expect(throws: LinuxWineEngineError.missingLibraryDirectory(
            noLibRoot.resolvingSymlinksInPath().appendingPathComponent("lib")
        )) {
            _ = try LinuxWineEngine.detect(id: "no-lib", at: noLibRoot)
        }
    }

    @Test func storeDeduplicatesReportsCorruptionAndEnforcesRemovalRules() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("linux-engine-store-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let registryURL = temp.appendingPathComponent("config/Wine Engines.json")
        let engineRoot = try Self.makeELFEngineTree(at: temp.appendingPathComponent("real-engine"))
        let symlinkRoot = temp.appendingPathComponent("symlink-engine")
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: engineRoot)

        let store = await MainActor.run {
            LinuxWineEngineStore(
                registryURL: registryURL,
                managedProvider: { LinuxWineEngineStore.ManagedRuntimeState(runtimeURL: nil, defaultPath: temp.appendingPathComponent("managed")) },
                environmentProvider: { ["PATH": "/usr/bin:/bin"] }
            )
        }

        try await MainActor.run {
            let first = try store.register(at: engineRoot, name: "Custom GE")
            let duplicate = try store.register(at: symlinkRoot, name: "Other Name")
            #expect(first.id == duplicate.id)
            #expect(store.list().engines.count == 2)
            #expect(store.list().engines[0].id == LinuxWineEngine.managedID)
            #expect(!store.list().engines[0].available)
            #expect(store.list().engines[1].id == first.id)
            #expect(store.anyEngineAvailable())

            #expect(throws: LinuxWineEngineStoreError.managedImmutable) {
                try store.remove(id: LinuxWineEngine.managedID) { _ in false }
            }
            #expect(throws: LinuxWineEngineStoreError.engineInUse(id: first.id)) {
                try store.remove(id: first.id) { $0 == first.id }
            }
            try store.remove(id: first.id) { _ in false }
            #expect(store.list().engines.count == 1)
            #expect(FileManager.default.fileExists(atPath: engineRoot.appendingPathComponent("bin/wine").path))

            // Corrupt registry must surface loadError without wiping data.
            try Data("not-json".utf8).write(to: registryURL)
            let listed = store.list()
            #expect(listed.engines.count == 1)
            #expect(listed.loadError != nil)
        }
    }

    @Test func bridgeEngineLifecycleSelectionOverridesAndLaunchGating() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("linux-engine-bridge-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let registryURL = temp.appendingPathComponent("Wine Engines.json")
        let setupRoot = temp.appendingPathComponent("setup-root", isDirectory: true)
        let nativeEngineDir = try Self.makeELFEngineTree(at: temp.appendingPathComponent("native-engine"))
        let foreignEngineDir = try Self.makeELFEngineTree(
            at: temp.appendingPathComponent("foreign-engine"),
            loaderArch: Self.foreignArchitecture(),
            serverArch: Self.foreignArchitecture()
        )
        let bottle = try Self.makeContainer(root: temp, name: "TestBottle")
        let jobs = await MainActor.run { BridgeJobStore() }
        let preferences = await MainActor.run {
            PreferencesService(
                fileURL: temp.appendingPathComponent("preferences.plist"),
                defaultBottleDirectory: temp
            )
        }
        let setup = await MainActor.run {
            LinuxWineSetupService(
                root: setupRoot,
                jobs: jobs,
                preferences: preferences,
                download: { _, _, _ in }
            )
        }
        let store = await MainActor.run {
            LinuxWineEngineStore(
                registryURL: registryURL,
                managedProvider: {
                    LinuxWineEngineStore.ManagedRuntimeState(
                        runtimeURL: setup.runtimeURL,
                        defaultPath: setupRoot.appendingPathComponent("current")
                    )
                },
                environmentProvider: { ["PATH": "/usr/bin:/bin"] }
            )
        }
        let probeState = ProbeControl()
        let services = await MainActor.run {
            LinuxApplicationServices(
                preferences: preferences,
                jobs: jobs,
                wineSetup: setup,
                engineStore: store,
                wineserverProbe: { _, _ in
                    try probeState.nextResult()
                }
            )
        }
        let workspace = ApplicationWorkspace(containers: [bottle])

        // Initially no managed install and no externals -> anyEngineAvailable == false.
        let initialStatus = try await services.call("setup.status", params: [:], workspace: workspace)
        #expect(initialStatus.object?["managedInstalled"] == .bool(false))
        #expect(initialStatus.object?["anyEngineAvailable"] == .bool(false))

        // Register native custom ELF engine -> setup.status reports anyEngineAvailable == true.
        let registered = try await services.call(
            "wine.engines.register",
            params: ["path": .string(nativeEngineDir.path), "name": .string("Linux Native Engine")],
            workspace: workspace
        )
        let engineID = try #require(registered.object?["id"]?.string)
        let fingerprint = try #require(registered.object?["fingerprint"]?.string)
        let statusWithExternal = try await services.call("setup.status", params: [:], workspace: workspace)
        #expect(statusWithExternal.object?["managedInstalled"] == .bool(false))
        #expect(statusWithExternal.object?["anyEngineAvailable"] == .bool(true))

        // Foreign ELF without translator registers cleanly as unavailable.
        let foreign = try await services.call(
            "wine.engines.register",
            params: ["path": .string(foreignEngineDir.path)],
            workspace: workspace
        )
        #expect(foreign.object?["available"] == .bool(false))
        let foreignID = try #require(foreign.object?["id"]?.string)

        // Selecting an unavailable foreign engine fails and preserves managed binding.
        await #expect(throws: BridgeFailure.self) {
            try await services.call(
                "wine.engines.select",
                params: ["container": .string(bottle.path), "id": .string(foreignID)],
                workspace: workspace
            )
        }
        let beforeSelect = try await services.call(
            "wine.engines.selection",
            params: ["container": .string(bottle.path)],
            workspace: workspace
        )
        #expect(beforeSelect.object?["engineID"] == .string(LinuxWineEngine.managedID))

        // Removing engine that is not bound succeeds.
        _ = try await services.call("wine.engines.remove", params: ["id": .string(foreignID)], workspace: workspace)

        // Select the native ELF engine onto `bottle`.
        let selected = try await services.call(
            "wine.engines.select",
            params: ["container": .string(bottle.path), "id": .string(engineID)],
            workspace: workspace
        )
        #expect(selected.object?["engineID"] == .string(engineID))
        #expect(selected.object?["fieldPolicy"]?.object?["dxvkAsync"]?.object?["disabled"] == .bool(true))

        // Attempting to remove bound engine fails with engine_in_use.
        do {
            _ = try await services.call("wine.engines.remove", params: ["id": .string(engineID)], workspace: workspace)
            Issue.record("Removing an engine bound to a bottle must fail")
        } catch let failure as BridgeFailure {
            #expect(failure.code == "engine_in_use")
        }

        // Launch config gates unconfirmed esync & dxvkAsync.
        let (resolvedEngine, _, unconfirmedOverrides) = await MainActor.run {
            try! store.resolveHost(for: bottle)
        }
        let gatedConfig = LinuxLaunchConfiguration.compose(
            values: [
                "enhancedSync": .text("esync"),
                "graphicsBackend": .text("dxvk"),
                "dxvkAsync": .boolean(true)
            ],
            bottleEnvironment: [:],
            bottleDLLOverrides: [],
            program: [:],
            engine: resolvedEngine,
            featureOverrides: unconfirmedOverrides
        )
        #expect(gatedConfig.environment["WINEESYNC"] == nil)
        #expect(gatedConfig.environment["DXVK_ASYNC"] == nil)
        #expect(gatedConfig.environment["WINEDLLOVERRIDES"] == nil)

        // Confirm esync without `confirmed: true` -> must fail.
        await #expect(throws: BridgeFailure.self) {
            try await services.call(
                "wine.engines.setFeatureOverride",
                params: [
                    "container": .string(bottle.path),
                    "feature": .string("esync"),
                    "enabled": .bool(true)
                ],
                workspace: workspace
            )
        }

        // Confirm esync & dxvkAsync with matching fingerprint -> unlocks both.
        let approvedEsync = try await services.call(
            "wine.engines.setFeatureOverride",
            params: [
                "container": .string(bottle.path),
                "feature": .string("esync"),
                "enabled": .bool(true),
                "confirmed": .bool(true),
                "fingerprint": .string(fingerprint)
            ],
            workspace: workspace
        )
        #expect(approvedEsync.object?["featureOverrides"]?.object?["esync"] == .string(fingerprint))
        #expect(
            approvedEsync.object?["fieldPolicy"]?.object?["enhancedSync"]?
                .object?["choices"]?.object?["esync"]?.object?["disabled"] == .bool(false)
        )

        let (_, _, updatedOverrides) = await MainActor.run {
            try! store.resolveHost(for: bottle)
        }
        let esyncOnlyConfig = LinuxLaunchConfiguration.compose(
            values: [
                "enhancedSync": .text("esync"),
                "dxvkAsync": .boolean(true)
            ],
            bottleEnvironment: [:],
            bottleDLLOverrides: [],
            program: [:],
            engine: resolvedEngine,
            featureOverrides: updatedOverrides
        )
        #expect(esyncOnlyConfig.environment["WINEESYNC"] == "1")
        #expect(esyncOnlyConfig.environment["DXVK_ASYNC"] == nil)

        // Approving dxvkAsync unlocks DXVK_ASYNC too.
        _ = try await services.call(
            "wine.engines.setFeatureOverride",
            params: [
                "container": .string(bottle.path),
                "feature": .string("dxvkAsync"),
                "enabled": .bool(true),
                "confirmed": .bool(true),
                "fingerprint": .string(fingerprint)
            ],
            workspace: workspace
        )
        let (_, _, fullOverrides) = await MainActor.run {
            try! store.resolveHost(for: bottle)
        }
        let enabledConfig = LinuxLaunchConfiguration.compose(
            values: [
                "enhancedSync": .text("esync"),
                "dxvkAsync": .boolean(true)
            ],
            bottleEnvironment: [:],
            bottleDLLOverrides: [],
            program: [:],
            engine: resolvedEngine,
            featureOverrides: fullOverrides
        )
        #expect(enabledConfig.environment["WINEESYNC"] == "1")
        #expect(enabledConfig.environment["DXVK_ASYNC"] == "1")

        // Replacing binary bytes / size on disk invalidates prior approvals automatically.
        let wineBinary = nativeEngineDir.appendingPathComponent("bin/wine")
        var updatedHeader = Self.elfHeaderData(architecture: Self.currentHostArchitecture())
        updatedHeader.append(contentsOf: [0x90, 0x90])
        try updatedHeader.write(to: wineBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wineBinary.path)
        let (mutatedEngine, _, staleOverrides) = await MainActor.run {
            try! store.resolveHost(for: bottle)
        }
        #expect(mutatedEngine.fingerprint != fingerprint)
        #expect(!mutatedEngine.featureEnabled(.esync, overrides: staleOverrides))

        // Stale fingerprint fails confirmation.
        do {
            _ = try await services.call(
                "wine.engines.setFeatureOverride",
                params: [
                    "container": .string(bottle.path),
                    "feature": .string("dxvk"),
                    "enabled": .bool(true),
                    "confirmed": .bool(true),
                    "fingerprint": .string("stale-fp")
                ],
                workspace: workspace
            )
            Issue.record("Stale fingerprint must fail")
        } catch let failure as BridgeFailure {
            #expect(failure.code == "fingerprint_mismatch")
        }

        // Creating a bottle with an unknown engineID fails before creating anything on disk.
        let parentDir = temp.appendingPathComponent("new-bottles", isDirectory: true)
        do {
            _ = try await services.call(
                "bottle.create",
                params: [
                    "name": .string("ShouldNotExist"),
                    "parent": .string(parentDir.path),
                    "windowsVersion": .string("win10"),
                    "engineID": .string("missing-engine")
                ],
                workspace: workspace
            )
            Issue.record("bottle.create with unknown engineID must fail")
        } catch let failure as BridgeFailure {
            #expect(failure.code == "unknown_engine")
        }
        #expect(!FileManager.default.fileExists(atPath: parentDir.path))

        // Live or indeterminate wineserver refuses rebind and keeps current binding.
        probeState.mode = .running
        do {
            _ = try await services.call(
                "wine.engines.select",
                params: ["container": .string(bottle.path), "id": .string(LinuxWineEngine.managedID)],
                workspace: workspace
            )
            Issue.record("select over running wineserver must fail")
        } catch let failure as BridgeFailure {
            #expect(failure.code == "engine_unavailable" || failure.code == "wineserver_running")
        }

        probeState.mode = .unknown
        do {
            _ = try await services.call(
                "wine.engines.select",
                params: ["container": .string(bottle.path), "id": .string(engineID)],
                workspace: workspace
            )
            Issue.record("select with unknown wineserver state must fail")
        } catch let failure as BridgeFailure {
            #expect(failure.code == "wineserver_unknown")
        }
        let stillBound = try await services.call(
            "wine.engines.selection",
            params: ["container": .string(bottle.path)],
            workspace: workspace
        )
        #expect(stillBound.object?["engineID"] == .string(engineID))
    }
}

private final class ProbeControl: @unchecked Sendable {
    enum Mode {
        case idle
        case running
        case unknown
    }

    private let lock = NSLock()
    private var _mode: Mode = .idle

    var mode: Mode {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue } }
    }

    func nextResult() throws -> Bool {
        switch mode {
        case .idle: return false
        case .running: return true
        case .unknown: throw BridgeFailure("process_query_failed", "simulated probe failure")
        }
    }
}
