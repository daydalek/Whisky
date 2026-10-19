//
//  WineGPURegistryTests.swift
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

@Suite("Wine GPU registry synchronization")
@MainActor
struct WineGPURegistryTests {
    private enum Failure: Error { case rejected }

    private func makeBottle() throws -> Bottle {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bottle = Bottle(bottleUrl: root, inFlight: false, isAvailable: true)
        bottle.settings.launcherCompatibilityMode = true
        bottle.settings.gpuSpoofing = true
        return bottle
    }

    @Test func failedImportsRetainMarkerAndRetryVendorAndDisableChanges() async throws {
        let bottle = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle.url) }
        await #expect(throws: Failure.rejected) {
            try await Wine.syncGPURegistry(bottle: bottle, importer: { _, _ in throw Failure.rejected })
        }
        #expect(GPURegistryState.load(from: bottle.url) == nil)
        var documents: [String] = []
        let importer: Wine.RegistryImporter = { document, _ in documents.append(document) }
        try await Wine.syncGPURegistry(bottle: bottle, importer: importer)
        #expect(documents.last?.contains(#""VideoPciVendorID"=dword:000010de"#) == true)
        #expect(documents.last?.contains(#""VideoPciDeviceID"=dword:00002684"#) == true)
        #expect(documents.last?.contains(#""VideoDescription"=-"#) == true)
        let nvidia = GPURegistryState.load(from: bottle.url)
        #expect(nvidia?.version == 1)
        bottle.settings.gpuVendor = .amd
        await #expect(throws: Failure.rejected) {
            try await Wine.syncGPURegistry(bottle: bottle, importer: { _, _ in throw Failure.rejected })
        }
        #expect(GPURegistryState.load(from: bottle.url) == nvidia)
        try await Wine.syncGPURegistry(bottle: bottle, importer: importer)
        #expect(documents.last?.contains(#""VideoPciVendorID"=dword:00001002"#) == true)
        let amd = GPURegistryState.load(from: bottle.url)
        bottle.settings.gpuSpoofing = false
        await #expect(throws: Failure.rejected) {
            try await Wine.syncGPURegistry(bottle: bottle, importer: { _, _ in throw Failure.rejected })
        }
        #expect(GPURegistryState.load(from: bottle.url) == amd)
        try await Wine.syncGPURegistry(bottle: bottle, importer: importer)
        #expect(documents.last?.contains(#""VideoPciVendorID"=-"#) == true)
        #expect(documents.last?.contains(#""VideoPciDeviceID"=-"#) == true)
        #expect(GPURegistryState.load(from: bottle.url)?.spoofingEnabled == false)
        let writes = documents.count
        try await Wine.syncGPURegistry(bottle: bottle, importer: importer)
        #expect(documents.count == writes)
    }

    @Test func legacySuccessMarkerIsReconciledThroughCheckedImport() async throws {
        let bottle = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle.url) }
        let old = ["spoofingEnabled": true, "vendor": "NVIDIA"] as [String: Any]
        let data = try PropertyListSerialization.data(fromPropertyList: old, format: .xml, options: 0)
        try data.write(to: GPURegistryState.markerURL(in: bottle.url))
        #expect(GPURegistryState.load(from: bottle.url)?.version == 0)
        var imports = 0
        try await Wine.syncGPURegistry(bottle: bottle, importer: { _, _ in imports += 1 })
        #expect(imports == 1)
        #expect(GPURegistryState.load(from: bottle.url)?.version == 1)
    }

    @Test func firstSteamClientStartupImportsPCIBeforeRunningClient() async throws {
        let bottle = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle.url) }
        var events: [String] = []
        let task = SteamLauncher.startClient(
            steamExe: bottle.url.appending(path: "steam.exe"), bottle: bottle,
            preparePrefix: { _ in events.append("prefix") },
            gpuImporter: { document, _ in
                #expect(document.contains(#""VideoPciVendorID"=dword:000010de"#))
                #expect(GPURegistryState.load(from: bottle.url) == nil)
                events.append("gpu")
            },
            run: { _, _, _, _ in
                #expect(GPURegistryState.load(from: bottle.url)?.spoofingEnabled == true)
                events.append("client")
            }
        )
        await task.value
        #expect(events == ["prefix", "gpu", "client"])
    }

    @Test func failedGPUImportBlocksFirstClientStartupAndLeavesRetryPossible() async throws {
        let bottle = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle.url) }
        var started = false
        let failed = SteamLauncher.startClient(
            steamExe: bottle.url.appending(path: "steam.exe"), bottle: bottle,
            preparePrefix: { _ in }, gpuImporter: { _, _ in throw Failure.rejected },
            run: { _, _, _, _ in started = true }
        )
        await failed.value
        #expect(!started)
        #expect(GPURegistryState.load(from: bottle.url) == nil)
        let retried = SteamLauncher.startClient(
            steamExe: bottle.url.appending(path: "steam.exe"), bottle: bottle,
            preparePrefix: { _ in }, gpuImporter: { _, _ in }, run: { _, _, _, _ in started = true }
        )
        await retried.value
        #expect(started)
    }
}
