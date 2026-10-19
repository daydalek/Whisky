//
//  Milestone2Challenger2Tests.swift
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

@Suite("Milestone 2 Challenger 2 Empirical Stress Tests")
@MainActor
struct Milestone2Challenger2Tests {
    // MARK: - Challenge 1: Custom selectedURL in subdirectories (SteamLauncher & SteamLibrary)

    @Test("executableURLs skips deep subdirectories while executableNames includes deeply nested selectedURL")
    func deepSubdirectorySelectedURLResolution() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "Challenge1_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let installURL = tempDir.appending(path: "UnrealGame")
        let level1 = installURL.appending(path: "Binaries")
        let level2 = installURL.appending(path: "Binaries/Win64")
        let level3 = installURL.appending(path: "Engine/Binaries/Win64")
        try FileManager.default.createDirectory(at: level1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: level2, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: level3, withIntermediateDirectories: true)

        let rootExe = installURL.appending(path: "Launcher.exe")
        let level1Exe = level1.appending(path: "CrashReportClient.exe")
        let level2Exe = level2.appending(path: "UnrealGame-Win64-Shipping.exe")
        let level3Exe = level3.appending(path: "EngineProcess.exe")

        try Data().write(to: rootExe)
        try Data().write(to: level1Exe)
        try Data().write(to: level2Exe)
        try Data().write(to: level3Exe)

        // 1. executableURLs should only scan root and level 1
        let discovered = SteamLibrary.executableURLs(under: installURL)
        let discoveredNames = Set(discovered.map { $0.lastPathComponent.lowercased() })
        #expect(discoveredNames.contains("launcher.exe"))
        #expect(discoveredNames.contains("crashreportclient.exe"))
        #expect(
            !discoveredNames.contains("unrealgame-win64-shipping.exe"),
            "executableURLs must not scan 2-levels deep"
        )
        #expect(!discoveredNames.contains("engineprocess.exe"), "executableURLs must not scan 3-levels deep")

        // 2. executableNames without selectedURL misses deep executable
        let namesDefault = SteamLibrary.executableNames(under: installURL)
        #expect(!namesDefault.contains("unrealgame-win64-shipping.exe"))

        // 3. executableNames with selectedURL includes 2-level and 3-level deep executables
        let namesWithLevel2 = SteamLibrary.executableNames(under: installURL, selectedURL: level2Exe)
        #expect(namesWithLevel2.contains("unrealgame-win64-shipping.exe"))
        #expect(namesWithLevel2.contains("launcher.exe"))

        let namesWithLevel3 = SteamLibrary.executableNames(under: installURL, selectedURL: level3Exe)
        #expect(namesWithLevel3.contains("engineprocess.exe"))
    }

    @Test("SteamLauncher.gameExecutables prepends selectedURL, deduplicates case-insensitively, and retains plan EXEs")
    func steamLauncherGameExecutablesPrecedenceAndDedup() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "Challenge1_Precedence_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let installURL = tempDir.appending(path: "Game")
        let deepDir = installURL.appending(path: "Bin/x64")
        try FileManager.default.createDirectory(at: deepDir, withIntermediateDirectories: true)

        let rootExe = installURL.appending(path: "DefaultLauncher.exe")
        let deepExe = deepDir.appending(path: "Game_Shipping.exe")
        try Data().write(to: rootExe)
        try Data().write(to: deepExe)

        var plan = LaunchPlan(
            overrides: ProgramOverrides(),
            gameProfileEnvironment: [:],
            provenance: []
        )
        plan.gameExecutables = ["PlanEntry.exe", "GAME_SHIPPING.EXE"] // Uppercase variant in plan

        let result = SteamLauncher.gameExecutables(installURL: installURL, selectedURL: deepExe, plan: plan)

        #expect(result.first == "Game_Shipping.exe", "selectedURL must have highest precedence (index 0)")
        #expect(
            result.filter { $0.lowercased() == "game_shipping.exe" }.count == 1,
            "Must deduplicate case-insensitively"
        )
        #expect(result.contains("DefaultLauncher.exe"))
        #expect(result.contains("PlanEntry.exe"))
    }

    @Test("SteamGameProgram selection and full SteamClientOrchestrator tracking and stop() integration")
    func orchestratorDeepSelectedURLTrackingAndStopping() async throws {
        let (bottle, games) = try SteamOrchestratorFixture.makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle.url) }
        let game = games[0]

        // Add a deeply nested executable inside game.installURL
        let deepDir = game.installURL.appending(path: "Binaries/Win64")
        try FileManager.default.createDirectory(at: deepDir, withIntermediateDirectories: true)
        let deepExe = deepDir.appending(path: "ShippingGame.exe")
        try Data().write(to: deepExe)

        // Select deep executable via SteamGameProgram
        try SteamGameProgram.select(deepExe, appID: game.appId, installURL: game.installURL, bottleURL: bottle.url)
        let loaded = try SteamGameProgram.selectedURL(
            appID: game.appId,
            installURL: game.installURL,
            bottleURL: bottle.url
        )
        #expect(loaded?.standardizedFileURL.path == deepExe.standardizedFileURL.path)

        // Configure Fake driver with script containing steam.exe and ShippingGame.exe
        // Fake driver will assign PID 100 to steam.exe and PID 101 to ShippingGame.exe
        let driver = FakeSteamClientDriver(script: [
            ["steam.exe", "ShippingGame.exe"]
        ])

        var timing = SteamOrchestratorFixture.patient
        timing.snapshotLifetime = 0.01
        let orchestrator = SteamClientOrchestrator(bottle: bottle, driver: driver, timing: timing)
        defer { orchestrator.stop() }

        // 1. Verify tracking finds game running via deep executable
        orchestrator.startTracking(games: [game])
        await SteamOrchestratorFixture.eventually("Game must be detected as running through deep ShippingGame.exe") {
            orchestrator.runningAppIds.contains(game.appId)
        }

        // 2. Verify stop kills the deep executable process (PID 101)
        await orchestrator.stop(game)
        #expect(driver.killed.contains(101), "stop() must terminate PID 101 (ShippingGame.exe)")
    }

    // MARK: - Challenge 2: WineGPURegistry Persistence and Vendor Transitions

    @Test("WineGPURegistry factory default stamp and idempotency")
    func gpuRegistryFactoryDefaultAndIdempotency() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "Challenge2_Factory_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bottle = Bottle(bottleUrl: tempDir, inFlight: false, isAvailable: true)
        #expect(GPURegistryState.load(from: tempDir) == nil)

        // First run on pristine bottle stamps factory default
        await Wine.syncGPURegistry(bottle: bottle)
        let firstStamp = GPURegistryState.load(from: tempDir)
        #expect(firstStamp == .factoryDefault)
        #expect(firstStamp?.spoofingEnabled == false)
        #expect(firstStamp?.vendor == "NVIDIA")

        // Second run is a no-op
        let beforeData = try Data(contentsOf: GPURegistryState.markerURL(in: tempDir))
        await Wine.syncGPURegistry(bottle: bottle)
        let afterData = try Data(contentsOf: GPURegistryState.markerURL(in: tempDir))
        #expect(beforeData == afterData)
    }

    @Test("WineGPURegistry vendor properties and state transitions")
    func gpuRegistryVendorPropertiesAndTransitions() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "Challenge2_Vendors_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Test vendor PCI integer values
        #expect(GPUVendor.nvidia.pciVendorIDInt == 0x10DE)
        #expect(GPUVendor.nvidia.pciDeviceIDInt == 0x2684)
        #expect(GPUVendor.nvidia.modelName == "NVIDIA GeForce RTX 4090")

        #expect(GPUVendor.amd.pciVendorIDInt == 0x1002)
        #expect(GPUVendor.amd.pciDeviceIDInt == 0x73FF)
        #expect(GPUVendor.amd.modelName == "AMD Radeon RX 6900 XT")

        #expect(GPUVendor.intel.pciVendorIDInt == 0x8086)
        #expect(GPUVendor.intel.pciDeviceIDInt == 0x9BC5)
        #expect(GPUVendor.intel.modelName == "Intel UHD Graphics 730")

        // Test marker transition chain: NVIDIA -> AMD -> Intel -> Disabled
        let state1 = GPURegistryState(spoofingEnabled: true, vendor: GPUVendor.nvidia.rawValue)
        try state1.save(to: tempDir)
        #expect(GPURegistryState.load(from: tempDir) == state1)

        let state2 = GPURegistryState(spoofingEnabled: true, vendor: GPUVendor.amd.rawValue)
        try state2.save(to: tempDir)
        #expect(GPURegistryState.load(from: tempDir) == state2)

        let state3 = GPURegistryState(spoofingEnabled: true, vendor: GPUVendor.intel.rawValue)
        try state3.save(to: tempDir)
        #expect(GPURegistryState.load(from: tempDir) == state3)

        let state4 = GPURegistryState(spoofingEnabled: false, vendor: GPUVendor.intel.rawValue)
        try state4.save(to: tempDir)
        #expect(GPURegistryState.load(from: tempDir) == state4)
    }

    // MARK: - Challenge 3: SteamLibrary Multi-Library Roots Handling

    @Test("libraryRoots handles secondary drives, missing folders, deduplication, and invalid VDFs")
    // swiftlint:disable:next function_body_length
    func libraryRootsMultiFolderAndMissingRoots() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: "Challenge3_Roots_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bottleURL = tempDir.appending(path: "Bottle")
        let driveC = bottleURL.appending(path: "drive_c")
        let dosdevices = bottleURL.appending(path: "dosdevices")
        let steamRoot = driveC.appending(path: "Program Files (x86)/Steam")
        let configDir = steamRoot.appending(path: "config")
        let steamapps = steamRoot.appending(path: "steamapps")
        let dDrive = tempDir.appending(path: "ExternalDrive/SteamLibrary")

        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dDrive, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dosdevices, withIntermediateDirectories: true)

        // Create symlink dosdevices/d: -> ExternalDrive
        let dLink = dosdevices.appending(path: "d:")
        try FileManager.default.createSymbolicLink(
            at: dLink,
            withDestinationURL: tempDir.appending(path: "ExternalDrive")
        )

        // Create libraryfolders.vdf containing:
        // "0": primary (C:\Program Files (x86)\Steam) -> duplicate of steamRoot
        // "1": secondary existing (D:\SteamLibrary)
        // "2": secondary MISSING on disk (E:\NonExistentLibrary)
        // "3": malformed escaping path
        let vdfContent = """
        "libraryfolders"
        {
            "0"
            {
                "path"      "C:\\\\Program Files (x86)\\\\Steam"
                "label"     ""
            }
            "1"
            {
                "path"      "D:\\\\SteamLibrary"
                "label"     "External"
            }
            "2"
            {
                "path"      "E:\\\\NonExistentLibrary"
                "label"     "Ghost"
            }
            "3"
            {
                "path"      "D:\\\\..\\\\..\\\\Escape"
                "label"     "Bad"
            }
        }
        """
        let vdfURL = configDir.appending(path: "libraryfolders.vdf")
        try vdfContent.write(to: vdfURL, atomically: true, encoding: .utf8)

        let roots = SteamLibrary.libraryRoots(steamRoot: steamRoot, bottleURL: bottleURL)
        print("  Discovered library roots: \(roots.map(\.path))")

        // 1. Must contain steamRoot
        #expect(roots.contains(where: { $0.standardizedFileURL.path == steamRoot.standardizedFileURL.path }))

        // 2. Must contain valid secondary library (D:\SteamLibrary)
        let expectedD = bottleURL.appending(path: "dosdevices/d:/SteamLibrary").standardizedFileURL.path
        #expect(roots.contains(where: { $0.standardizedFileURL.path == expectedD }))

        // 3. Must NOT contain non-existent library E:\NonExistentLibrary
        #expect(!roots.contains(where: { $0.path.contains("NonExistentLibrary") }))

        // 4. Must NOT contain escaped path
        #expect(!roots.contains(where: { $0.path.contains("Escape") }))

        // 5. Must NOT duplicate primary root
        let steamRootMatches = roots.filter { $0.standardizedFileURL.path == steamRoot.standardizedFileURL.path }
        #expect(steamRootMatches.count == 1, "steamRoot must not be duplicated")
    }
}
