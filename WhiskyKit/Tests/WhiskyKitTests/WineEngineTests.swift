//
//  WineEngineTests.swift
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

@Suite("Wine engine detection and registry")
struct WineEngineTests {
    // MARK: - Fixtures

    private func temporaryRoot(_ label: String = "engine") throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A real Mach-O binary usable as a fixture executable: the host's
    /// `/usr/bin/true` is a genuine arm64 thin Mach-O, unlike a shell script,
    /// which detection must (and does) reject.
    private func copyTrueBinary(to url: URL) throws {
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"), to: url
        )
    }

    /// Thin Mach-O header claiming `cputype` with `MH_EXECUTE` filetype —
    /// detection validates the whole header, not just magic and CPU.
    private func writeThinMachO(cputype: UInt32, to url: URL) throws {
        var header = Data(count: 64 * 1_024)
        // MH_MAGIC_64 (0xFEEDFACF) little-endian, then cputype + MH_EXECUTE.
        withUnsafeBytes(of: UInt32(0xFEED_FACF).littleEndian) { header.replaceSubrange(0 ..< 4, with: $0) }
        withUnsafeBytes(of: cputype.littleEndian) { header.replaceSubrange(4 ..< 8, with: $0) }
        withUnsafeBytes(of: UInt32(2).littleEndian) { header.replaceSubrange(12 ..< 16, with: $0) }
        try header.write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
    }

    /// FAT_MAGIC_64 binary with one real thin `MH_EXECUTE` slice per cputype:
    /// the entry table declares in-file ranges, and each declared range
    /// carries a matching thin header the parser can reach.
    private func writeFatMachO(cputypes: [UInt32], to url: URL) throws {
        let entrySize = 32
        let sliceSize = 4 * 1_024
        var file = Data(count: 64 * 1_024)
        withUnsafeBytes(of: UInt32(0xCAFE_BABF).bigEndian) { file.replaceSubrange(0 ..< 4, with: $0) }
        withUnsafeBytes(of: UInt32(cputypes.count).bigEndian) { file.replaceSubrange(4 ..< 8, with: $0) }
        for (index, cputype) in cputypes.enumerated() {
            let entry = 8 + index * entrySize
            let sliceOffset = 8 + cputypes.count * entrySize + index * sliceSize
            withUnsafeBytes(of: cputype.bigEndian) {
                file.replaceSubrange(entry ..< entry + 4, with: $0)
            }
            withUnsafeBytes(of: UInt64(sliceOffset).bigEndian) {
                file.replaceSubrange(entry + 8 ..< entry + 16, with: $0)
            }
            withUnsafeBytes(of: UInt64(sliceSize).bigEndian) {
                file.replaceSubrange(entry + 16 ..< entry + 24, with: $0)
            }
            withUnsafeBytes(of: UInt32(0xFEED_FACF).littleEndian) {
                file.replaceSubrange(sliceOffset ..< sliceOffset + 4, with: $0)
            }
            withUnsafeBytes(of: cputype.littleEndian) {
                file.replaceSubrange(sliceOffset + 4 ..< sliceOffset + 8, with: $0)
            }
            withUnsafeBytes(of: UInt32(2).littleEndian) {
                file.replaceSubrange(sliceOffset + 12 ..< sliceOffset + 16, with: $0)
            }
        }
        try file.write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
    }

    /// `bin/` + `lib/` standard engine root with real Mach-O executables.
    private func makeEngine(
        at root: URL,
        wineOnly: Bool = false,
        dxvk: Bool = false
    ) throws {
        let bin = root.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "lib"), withIntermediateDirectories: true)
        if !wineOnly {
            try copyTrueBinary(to: bin.appending(path: "wine64"))
        }
        try copyTrueBinary(to: bin.appending(path: wineOnly ? "wine" : "wineserver"))
        if wineOnly {
            try copyTrueBinary(to: bin.appending(path: "wineserver"))
        }
        if dxvk {
            try writeDXVKPayload(at: root.appending(path: "DXVK"))
        }
    }

    /// A fake native PE DLL: `MZ` magic plus enough bytes that the 16-byte
    /// marker slot at 0x40 exists and does not read "Wine builtin DLL" —
    /// the exact signal `Wine.isNativePE` distinguishes on.
    private func writeFakePE(to url: URL) throws {
        var data = Data(repeating: 0, count: 0x60)
        data[0] = 0x4D // M
        data[1] = 0x5A // Z
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    /// The complete DXVK deployment set: the preset DLLs in both arch
    /// tiers, each a fake PE binary. No `dxgi.dll` — the real DXVK-macOS
    /// package ships none and the launcher reconciles the builtin instead.
    private func writeDXVKPayload(at payload: URL) throws {
        for arch in ["x64", "x32"] {
            for name in ["d3d9", "d3d10core", "d3d11"] {
                try writeFakePE(to: payload.appending(path: arch).appending(path: "\(name).dll"))
            }
        }
    }

    // MARK: - Detection

    @Test func detectsStandardLayout() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeEngine(at: root)

        let engine = try WineEngine.detect(at: root)
        #expect(engine.isAvailable)
        #expect(!engine.isManaged)
        #expect(engine.wineBinary.lastPathComponent == "wine64")
        #expect(engine.wineserverBinary.lastPathComponent == "wineserver")
        #expect(engine.architectures.contains("arm64"))
        #expect(!engine.fingerprint.isEmpty)
    }

    @Test func detectsNestedWineLayoutWithPayloads() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let wineRoot = root.appending(path: "Wine")
        try makeEngine(at: wineRoot)
        // The surrounding directory carries the payload root → `librariesURL`.
        try writeDXVKPayload(at: root.appending(path: "DXVK"))

        let engine = try WineEngine.detect(at: root)
        #expect(engine.isAvailable)
        #expect(engine.librariesURL?.standardizedFileURL == root.standardizedFileURL)
        #expect(engine.payloadRoot(.dxvk) != nil)
        // Complete payload files are present, but presence is never proof of
        // support on an external engine — the feature stays confirmable.
        #expect(engine.status(of: .dxvk).state == .unverified)
        #expect(engine.status(of: .dxvk).canOverride)
    }

    @Test func bareTreeDoesNotBorrowSiblingPayloads() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A managed-style package: Libraries/Wine plus a DXVK payload root.
        let libraries = root.appending(path: "Libraries")
        try makeEngine(at: libraries.appending(path: "Wine"))
        try writeDXVKPayload(at: libraries.appending(path: "DXVK"))
        // A bare tree right next to it must not inherit those payloads.
        let other = root.appending(path: "OtherWine")
        try makeEngine(at: other)

        let bare = try WineEngine.detect(at: other)
        #expect(bare.librariesURL == nil)
        #expect(bare.payloadRoot(.dxvk) == nil)
        #expect(bare.status(of: .dxvk).state == .unavailable)

        // Selecting the package root itself does see its payload root.
        let packaged = try WineEngine.detect(at: libraries)
        #expect(packaged.payloadRoot(.dxvk) != nil)
    }

    @Test func detectsWineOnlyLoader() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Only `bin/wine`, no `wine64`.
        let bin = root.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "lib"), withIntermediateDirectories: true)
        try copyTrueBinary(to: bin.appending(path: "wine"))
        try copyTrueBinary(to: bin.appending(path: "wineserver"))

        let engine = try WineEngine.detect(at: root)
        #expect(engine.wineBinary.lastPathComponent == "wine")
    }

    @Test func detectsPathsWithSpacesUnicodeAndQuotes() throws {
        let base = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appending(path: "My Wine 引擎 'quoted'")
        try makeEngine(at: root)

        let engine = try WineEngine.detect(at: root)
        #expect(engine.isAvailable)
        #expect(engine.wineBinary.path.contains("My Wine 引擎 'quoted'"))
    }

    @Test func rejectsMissingLoaderServerAndLibrary() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "lib"), withIntermediateDirectories: true)

        // No loader at all.
        #expect(throws: WineEngineError.self) { try WineEngine.detect(at: root) }

        // Loader present, no wineserver.
        try copyTrueBinary(to: bin.appending(path: "wine64"))
        #expect(throws: WineEngineError.self) { try WineEngine.detect(at: root) }

        // Loader + server, no lib.
        try copyTrueBinary(to: bin.appending(path: "wineserver"))
        try FileManager.default.removeItem(at: root.appending(path: "lib"))
        #expect(throws: WineEngineError.self) { try WineEngine.detect(at: root) }
    }

    @Test func rejectsNonExecutableAndScriptLoaders() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeEngine(at: root)

        // Scripts are not Mach-O — a common "wrapper" trap.
        let script = root.appending(path: "bin").appending(path: "wine64")
        try FileManager.default.removeItem(at: script)
        try Data("#!/bin/sh\nexec /opt/real/bin/wine64 \"$@\"\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        #expect(throws: WineEngineError.self) { try WineEngine.detect(at: root) }

        // Real Mach-O without the executable bit.
        try FileManager.default.removeItem(at: script)
        try copyTrueBinary(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: script.path)
        #expect(throws: WineEngineError.self) { try WineEngine.detect(at: root) }
    }

    @Test func rejectsWrongArchitectureAndMismatchedSlices() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeEngine(at: root)

        // i386-only loader: valid Mach-O, no usable slice.
        let bin = root.appending(path: "bin")
        try writeThinMachO(cputype: 0x0000_0007, to: bin.appending(path: "wine64"))
        #expect(throws: WineEngineError.self) { try WineEngine.detect(at: root) }

        // Loader arm64 + server i386-only: no shared slice.
        try FileManager.default.removeItem(at: bin.appending(path: "wine64"))
        try copyTrueBinary(to: bin.appending(path: "wine64"))
        try writeThinMachO(cputype: 0x0000_0007, to: bin.appending(path: "wineserver"))
        #expect(throws: WineEngineError.self) { try WineEngine.detect(at: root) }
    }

    @Test func acceptsFatBinarySlices() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "lib"), withIntermediateDirectories: true)
        try writeFatMachO(cputypes: [0x0100_0007, 0x0100_000C], to: bin.appending(path: "wine64"))
        try writeFatMachO(cputypes: [0x0100_000C], to: bin.appending(path: "wineserver"))

        let engine = try WineEngine.detect(at: root)
        // Architectures are the slices loader AND server can both execute —
        // the loader's extra x86_64 slice cannot run with an arm64-only server.
        #expect(engine.architectures == ["arm64"])
    }

    @Test func resolvesSymlinkRoots() throws {
        let base = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appending(path: "real-engine")
        try makeEngine(at: real)
        let link = base.appending(path: "link-engine")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let engine = try WineEngine.detect(at: link)
        #expect(engine.isAvailable)
        #expect(engine.rootURL.resolvingSymlinksInPath() == real.resolvingSymlinksInPath())
    }

    // MARK: - Registry

    @Test func registersListsResolvesAndRemovesWithoutDeleting() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engineRoot = root.appending(path: "engine")
        try makeEngine(at: engineRoot)
        let store = WineEngineStore(
            registryURL: root.appending(path: "engines.json"),
            referencedEngineIDs: { [] }
        )

        let engine = try store.register(at: engineRoot, name: "Test Engine")
        #expect(engine.isAvailable)
        #expect(store.list().contains { $0.id == engine.id && $0.isAvailable })
        #expect(store.list().first?.isManaged == true)

        let resolved = try store.resolve(id: engine.id)
        #expect(resolved.id == engine.id)
        #expect(resolved.fingerprint == engine.fingerprint)

        try store.remove(id: engine.id)
        // Removal drops the record only — files stay on disk.
        #expect(FileManager.default.fileExists(atPath: engine.wineBinary.path))
        #expect(
            !FileManager.default.fileExists(atPath: store.registryURL.path)
                || store.list().allSatisfy { $0.isManaged || $0.id != engine.id }
        )
        #expect(throws: WineEngineError.self) { try store.resolve(id: engine.id) }
    }

    @Test func deduplicatesCanonicalRoots() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engineRoot = root.appending(path: "engine")
        try makeEngine(at: engineRoot)
        let link = root.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: engineRoot)
        let store = WineEngineStore(
            registryURL: root.appending(path: "engines.json"),
            referencedEngineIDs: { [] }
        )

        let first = try store.register(at: engineRoot)
        let second = try store.register(at: link)
        #expect(first.id == second.id)
        #expect(store.list().filter { !$0.isManaged }.count == 1)
    }

    @Test func survivesRegistryCorruptionAndUnknownIds() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registryURL = root.appending(path: "engines.json")
        try Data("not json".utf8).write(to: registryURL)
        let store = WineEngineStore(registryURL: registryURL, referencedEngineIDs: { [] })

        // Corruption fails closed: managed is still listed, the error is
        // surfaced, nothing silently pretends the file was empty.
        #expect(store.list().map(\.id) == [WineEngine.managedID])
        #expect(store.lastLoadError != nil)
        #expect(throws: WineEngineError.self) { try store.resolve(id: "ghost") }
        #expect(throws: WineEngineError.self) { try store.remove(id: WineEngine.managedID) }
    }

    @Test func refusesRemovingEngineStillInUse() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engineRoot = root.appending(path: "engine")
        try makeEngine(at: engineRoot)
        let referenced = ReferencedIDs()
        let store = WineEngineStore(
            registryURL: root.appending(path: "engines.json"),
            referencedEngineIDs: { referenced.ids }
        )
        let engine = try store.register(at: engineRoot)
        referenced.ids.insert(engine.id)
        #expect(throws: WineEngineError.self) { try store.remove(id: engine.id) }
        referenced.ids.removeAll()
        try store.remove(id: engine.id)
    }

    // MARK: - Feature policy

    @Test func externalEnginesGateUnverifiedAndPayloadFeatures() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeEngine(at: root)
        let engine = try WineEngine.detect(at: root)

        // No DXVK payload → unavailable, and no confirmation can enable it.
        #expect(engine.status(of: .dxvk).state == .unavailable)
        #expect(!engine.isFeatureEnabled(.dxvk, overrides: ["dxvk": engine.fingerprint]))
        // msync is unverified: an approval must match the *current* fingerprint.
        #expect(engine.status(of: .msync).state == .unverified)
        #expect(!engine.isFeatureEnabled(.msync))
        #expect(engine.isFeatureEnabled(.msync, overrides: ["msync": engine.fingerprint]))
        #expect(!engine.isFeatureEnabled(.msync, overrides: ["msync": "stale-fingerprint"]))
    }

    @Test func fingerprintChangeExpiresApprovals() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeEngine(at: root)
        let before = try WineEngine.detect(at: root)
        let overrides = ["msync": before.fingerprint]
        #expect(before.isFeatureEnabled(.msync, overrides: overrides))

        // Replacing the loader changes the fingerprint → the saved approval
        // no longer applies.
        let loader = root.appending(path: "bin").appending(path: "wine64")
        try FileManager.default.removeItem(at: loader)
        try writeThinMachO(cputype: 0x0100_000C, to: loader)
        let after = try WineEngine.detect(at: root)
        #expect(after.fingerprint != before.fingerprint)
        #expect(!after.isFeatureEnabled(.msync, overrides: overrides))
    }

    @Test func incompleteOrFakeDXVKPayloadIsUnavailableNotConfirmable() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeEngine(at: root)
        // Only x64/d3d11 — what the old check accepted. Missing x32 must fail.
        let dxvk = root.appending(path: "DXVK")
        try writeFakePE(to: dxvk.appending(path: "x64/d3d11.dll"))
        var engine = try WineEngine.detect(at: root)
        #expect(engine.status(of: .dxvk).state == .unavailable)
        #expect(!engine.status(of: .dxvk).canOverride)

        // Full file set but fake "dxvk" bytes, not PE binaries → still out.
        try FileManager.default.removeItem(at: dxvk)
        for arch in ["x64", "x32"] {
            for name in ["d3d9", "d3d10core", "d3d11"] {
                let dll = dxvk.appending(path: "\(arch)/\(name).dll")
                try FileManager.default.createDirectory(
                    at: dll.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try Data("dxvk".utf8).write(to: dll)
            }
        }
        engine = try WineEngine.detect(at: root)
        #expect(engine.status(of: .dxvk).state == .unavailable)

        // Complete macOS layout — no dxgi.dll at all — is still a full
        // payload: unverified and confirmable, never supported.
        try FileManager.default.removeItem(at: dxvk)
        try writeDXVKPayload(at: dxvk)
        engine = try WineEngine.detect(at: root)
        #expect(engine.status(of: .dxvk).state == .unverified)
        #expect(engine.status(of: .dxvk).canOverride)

        // One required DLL missing (x32 has no d3d11) → unavailable.
        try FileManager.default.removeItem(
            at: dxvk.appending(path: "x32/d3d11.dll")
        )
        engine = try WineEngine.detect(at: root)
        #expect(engine.status(of: .dxvk).state == .unavailable)

        // dxgi is optional, but a SHIPPED fake dxgi is still validated.
        try writeDXVKPayload(at: dxvk)
        try Data("dxgi".utf8).write(to: dxvk.appending(path: "x64/dxgi.dll"))
        engine = try WineEngine.detect(at: root)
        #expect(engine.status(of: .dxvk).state == .unavailable)
    }

    @Test func coreMLPayloadUsesThePackagedLayout() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeEngine(at: root)
        let upscalers = root.appending(path: "lib/wine/x86_64-unix/gdi-upscalers")
        let coreml = upscalers.appending(path: "coreml")
        try FileManager.default.createDirectory(at: coreml, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: coreml.appending(path: "manifest.json"))
        try FileManager.default.createDirectory(
            at: coreml.appending(path: "model.mlmodelc"), withIntermediateDirectories: true
        )
        // The helper lives at the gdi-upscalers root, next to the dylib —
        // not inside `coreml/` where the old check looked for it.
        try writeFakePE(to: upscalers.appending(path: "winegdi-coreml-helper"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: upscalers.appending(path: "winegdi-coreml-helper").path
        )

        var engine = try WineEngine.detect(at: root)
        #expect(engine.status(of: .gdiCoreML).state == .unverified)

        // Manifest or models missing → unavailable, not confirmable.
        try FileManager.default.removeItem(at: coreml.appending(path: "model.mlmodelc"))
        engine = try WineEngine.detect(at: root)
        #expect(engine.status(of: .gdiCoreML).state == .unavailable)
    }

    @Test func metalTogglesAreGenericNotD3DMetalBound() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeEngine(at: root)
        let engine = try WineEngine.detect(at: root)
        // No D3DMetal payload: the generic Metal HUD/trace/validation gate is
        // still confirmable — DXMT uses Metal too. Only its approval does not
        // unlock D3DMetal-specific fields (checked at the env layer).
        #expect(engine.status(of: .metal).state == .unverified)
        #expect(engine.status(of: .metalFX).state == .unavailable)
        #expect(engine.status(of: .frameGeneration).state == .unavailable)
    }

    @Test func inPlaceLibraryModuleChangeExpiresApprovals() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeEngine(at: root)
        // A rebuild confined to `lib` — parent directories keep their mtimes.
        let ntdll = root.appending(path: "lib/wine/x86_64-unix/ntdll.so")
        try writeFakePE(to: ntdll)
        let before = try WineEngine.detect(at: root)
        let overrides = ["msync": before.fingerprint]
        #expect(before.isFeatureEnabled(.msync, overrides: overrides))

        // Rewrite ntdll in place (a different size so metadata differs
        // deterministically — contents are never hashed).
        try FileManager.default.removeItem(at: ntdll)
        var bigger = Data(repeating: 0, count: 0x80)
        bigger[0] = 0x4D
        bigger[1] = 0x5A
        try bigger.write(to: ntdll)
        let after = try WineEngine.detect(at: root)
        #expect(after.fingerprint != before.fingerprint)
        #expect(!after.isFeatureEnabled(.msync, overrides: overrides))
    }

    @Test func managedEngineKeepsDefaultBehavior() {
        let managed = WineEngine.managed
        #expect(managed.isManaged)
        #expect(managed.isFeatureEnabled(.msync))
        #expect(managed.isFeatureEnabled(.dxvk))
    }

    // MARK: - Bottle settings persistence

    @Test func bottleSettingsRoundTripEngineFields() throws {
        var config = BottleWineConfig()
        #expect(config.engineID == WineEngine.managedID)
        #expect(config.featureOverrides.isEmpty)

        config.engineID = "engine-abc"
        config.featureOverrides = ["msync": "fp-1"]
        let data = try PropertyListEncoder().encode(config)
        let decoded = try PropertyListDecoder().decode(BottleWineConfig.self, from: data)
        #expect(decoded.engineID == "engine-abc")
        #expect(decoded.featureOverrides == ["msync": "fp-1"])
    }

    @Test func bottleSettingsDecodeDefaultsToManaged() throws {
        // A settings blob written before engines existed has no keys at all.
        let minimal: [String: String] = [:]
        let data = try PropertyListSerialization.data(
            fromPropertyList: minimal, format: .binary, options: 0
        )
        let settings = try PropertyListDecoder().decode(BottleSettings.self, from: data)
        #expect(settings.wineEngineID == WineEngine.managedID)
        #expect(settings.wineFeatureOverrides.isEmpty)
    }
}

/// Mutable box so `referencedEngineIDs` stays `@Sendable` while tests mutate
/// the in-use set between calls.
private final class ReferencedIDs: @unchecked Sendable {
    var ids = Set<String>()
}
