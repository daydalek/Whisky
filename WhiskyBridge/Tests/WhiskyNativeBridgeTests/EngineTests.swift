//
//  EngineTests.swift
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
import WhiskyKit
@testable import WhiskyNativeBridge

/// Temp workspace with one registered bottle and an isolated engine registry.
private struct EngineFixture {
    let root: URL
    let container: URL
    let registryURL: URL
    let engineRegistryURL: URL
    let engineRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisky-engines-\(UUID())")
        container = root.appendingPathComponent("Bottle")
        registryURL = root.appendingPathComponent("BottleVM.plist")
        engineRegistryURL = root.appendingPathComponent("Wine Engines.json")
        engineRoot = root.appendingPathComponent("Engine")
        try FileManager.default.createDirectory(
            at: container.appendingPathComponent("drive_c"),
            withIntermediateDirectories: true
        )
        // A real BottleSettings plist: the removal ref-check fails closed on
        // unreadable metadata, so the fixture container must decode cleanly.
        try PropertyListEncoder().encode(BottleSettings())
            .write(to: container.appendingPathComponent("Metadata.plist"))
        var registry = BottleData(registryURL: registryURL)
        registry.paths = [container]
        try Self.makeEngine(at: engineRoot)
    }

    var workspace: ApplicationWorkspace {
        ApplicationWorkspace(registry: registryURL)
    }

    /// A bare external engine: real Mach-O binaries so detection accepts it.
    /// `wine64` is `/usr/bin/true` (any launch "succeeds"); `wineserver` is
    /// `/usr/bin/false` so the `-k0` liveness probe reports *not running*
    /// instead of a false-positive busy state.
    static func makeEngine(at root: URL, dxvk: Bool = false) throws {
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("lib"), withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"), to: bin.appendingPathComponent("wine64")
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/false"), to: bin.appendingPathComponent("wineserver")
        )
        if dxvk {
            // The complete macOS deployment set — d3d9/d3d10core/d3d11 in
            // both tiers, fake PE binaries; no dxgi.dll like real packages.
            for arch in ["x64", "x32"] {
                for name in ["d3d9", "d3d10core", "d3d11"] {
                    let dll = root.appendingPathComponent("DXVK/\(arch)/\(name).dll")
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

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor private func engineService(
    fixture: EngineFixture,
    wineEnabled: Bool = true,
    referencedEngineIDs: (@Sendable () -> Set<String>)? = nil
) -> MacOSApplicationServices {
    MacOSApplicationServices(
        wineEnabled: wineEnabled,
        preferencesDomain: "com.daydalek.Maltoria.engines.\(UUID().uuidString)",
        jobs: BridgeJobStore(),
        engineStore: WineEngineStore(
            registryURL: fixture.engineRegistryURL,
            referencedEngineIDs: referencedEngineIDs ?? { [] }
        )
    )
}

private func engineList(_ reply: JSONValue) -> [JSONValue] {
    reply.object?["engines"]?.array ?? []
}

private func containerParam(_ fixture: EngineFixture) -> [String: JSONValue] {
    ["container": .string(fixture.container.path)]
}

@Test @MainActor func listReportsManagedAndRegisteredEngines() async throws {
    let fixture = try EngineFixture()
    defer { fixture.remove() }
    let service = engineService(fixture: fixture)

    let initial = try await service.call(
        "wine.engines.list", params: [:], workspace: fixture.workspace
    )
    let before = engineList(initial)
    #expect(before.count == 1)
    #expect(before.first?.object?["managed"] == .bool(true))
    // `available` is deliberately NOT asserted: it reflects whether a managed
    // runtime is installed on the test host, which must not matter here.

    let registered = try await service.call(
        "wine.engines.register",
        params: ["path": .string(fixture.engineRoot.path), "name": .string("External 10")],
        workspace: fixture.workspace
    )
    #expect(registered.object?["managed"] == .bool(false))
    #expect(registered.object?["name"] == .string("External 10"))
    #expect(registered.object?["available"] == .bool(true))
    #expect((registered.object?["fingerprint"]?.string?.isEmpty) == false)
    #expect(registered.object?["features"]?.array?.isEmpty == false)

    let after = try await engineList(service.call(
        "wine.engines.list", params: [:], workspace: fixture.workspace
    ))
    #expect(after.count == 2)
}

@Test @MainActor func registerRejectsNonEngineDirectory() async throws {
    let fixture = try EngineFixture()
    defer { fixture.remove() }
    let service = engineService(fixture: fixture)

    do {
        _ = try await service.call(
            "wine.engines.register",
            params: ["path": .string(fixture.container.path)],
            workspace: fixture.workspace
        )
        Issue.record("registering a bottle directory must fail")
    } catch let error as BridgeFailure {
        #expect(error.code == "engine_rejected")
    }
}

@Test @MainActor func selectionReadsBackManagedDefault() async throws {
    let fixture = try EngineFixture()
    defer { fixture.remove() }
    let service = engineService(fixture: fixture)

    let selection = try await service.call(
        "wine.engines.selection", params: containerParam(fixture), workspace: fixture.workspace
    )
    #expect(selection.object?["engineID"] == .string(WineEngine.managedID))
    #expect(selection.object?["engine"]?.object?["managed"] == .bool(true))
    #expect(selection.object?["features"]?.array?.isEmpty == false)
    #expect(selection.object?["fieldPolicy"]?.object != nil)
}

@Test @MainActor func selectPersistsEngineAndReadbackReflectsIt() async throws {
    let fixture = try EngineFixture()
    defer { fixture.remove() }
    let service = engineService(fixture: fixture)
    let registered = try await service.call(
        "wine.engines.register",
        params: ["path": .string(fixture.engineRoot.path)],
        workspace: fixture.workspace
    )
    let id = try #require(registered.object?["id"]?.string)

    var params = containerParam(fixture)
    params["id"] = .string(id)
    let reply = try await withIdleWineProbes {
        try await service.call(
            "wine.engines.select", params: params, workspace: fixture.workspace
        )
    }
    #expect(reply.object?["engineID"] == .string(id))
    #expect(reply.object?["engine"]?.object?["managed"] == .bool(false))

    // The binding is persisted on the bottle, not just cached: a fresh
    // service with the same registry reads it back.
    let fresh = engineService(fixture: fixture)
    let readback = try await fresh.call(
        "wine.engines.selection", params: containerParam(fixture), workspace: fixture.workspace
    )
    #expect(readback.object?["engineID"] == .string(id))
    // A saved default-DXMT choice stays recorded but is reported disabled:
    // external engines never get managed payload assumptions.
    let features = readback.object?["features"]?.array ?? []
    let dxvk = features.first { $0.object?["id"] == .string("dxvk") }
    #expect(dxvk?.object?["state"] == .string("unavailable"))
    #expect(dxvk?.object?["enabled"] == .bool(false))
}

@Test @MainActor func failedSelectKeepsPreviousBinding() async throws {
    let fixture = try EngineFixture()
    defer { fixture.remove() }
    let service = engineService(fixture: fixture)

    var params = containerParam(fixture)
    params["id"] = .string("no-such-engine")
    do {
        _ = try await service.call("wine.engines.select", params: params, workspace: fixture.workspace)
        Issue.record("selecting an unknown engine must fail")
    } catch let error as BridgeFailure {
        #expect(error.code == "unknown_engine")
    }

    let selection = try await service.call(
        "wine.engines.selection", params: containerParam(fixture), workspace: fixture.workspace
    )
    #expect(selection.object?["engineID"] == .string(WineEngine.managedID))
}

@Test @MainActor func selectRejectsBusyContainer() async throws {
    let fixture = try EngineFixture()
    defer { fixture.remove() }
    let service = engineService(fixture: fixture)

    // Hold a lifecycle job open so `hasLifecycleOperation` is true.
    let gate = JobGate()
    _ = try service.jobs.start(name: "bottle.rename") { _ in
        await gate.wait()
        return .null
    }
    #expect(service.jobs.hasLifecycleOperation)

    var params = containerParam(fixture)
    params["id"] = .string(WineEngine.managedID)
    do {
        _ = try await service.call("wine.engines.select", params: params, workspace: fixture.workspace)
        Issue.record("select on a busy container must fail")
    } catch let error as BridgeFailure {
        #expect(error.code == "container_busy")
    }
    await gate.open()
}

/// A thread-safe capture for the injected probe.
private final class ProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var wineservers: [URL] = []

    func record(_ wineserver: URL) {
        lock.lock()
        defer { lock.unlock() }
        wineservers.append(wineserver)
    }

    var recorded: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return wineservers
    }
}

/// Neutralizes both probe paths so a test never depends on a host wineserver
/// or a managed runtime install: the per-engine probe reports `probe` (idle
/// by default), the host-wide `pgrep` probe reports idle too.
@MainActor private func withIdleWineProbes<T>(
    probe: (@Sendable (URL, URL) async throws -> Bool)? = nil,
    _ body: () async throws -> T
) async throws -> T {
    try await Wine.$wineserverProbeOverride.withValue(probe ?? { _, _ in false }) {
        // One closure stays a bound constant so the call keeps a single
        // literal + one trailing closure (both linters agree on that form).
        let hostIdle: @Sendable () async throws -> Bool = { false }
        return try await Wine.$anyWineserverRunning.withValue(hostIdle) {
            try await body()
        }
    }
}

/// Two registered engines, one container: reselecting A→B must probe the
/// BOUND engine's server (A's), not the target's and not the global store's.
@Test @MainActor func selectExternalAToExternalBProbesBoundEngine() async throws {
    let fixture = try EngineFixture()
    defer { fixture.remove() }
    let service = engineService(fixture: fixture)

    let rootB = fixture.root.appendingPathComponent("EngineB")
    try EngineFixture.makeEngine(at: rootB)
    let replyA = try await service.call(
        "wine.engines.register",
        params: ["path": .string(fixture.engineRoot.path)],
        workspace: fixture.workspace
    )
    let idA = try #require(replyA.object?["id"]?.string)
    let replyB = try await service.call(
        "wine.engines.register",
        params: ["path": .string(rootB.path)],
        workspace: fixture.workspace
    )
    let idB = try #require(replyB.object?["id"]?.string)

    var params = containerParam(fixture)
    params["id"] = .string(idA)
    try await withIdleWineProbes {
        _ = try await service.call("wine.engines.select", params: params, workspace: fixture.workspace)
    }

    let box = ProbeBox()
    params["id"] = .string(idB)
    let recording: @Sendable (URL, URL) async throws -> Bool = { wineserver, _ in
        box.record(wineserver)
        return false
    }
    let reply = try await withIdleWineProbes(probe: recording) {
        try await service.call("wine.engines.select", params: params, workspace: fixture.workspace)
    }
    #expect(reply.object?["engineID"] == .string(idB))
    // The second select probed the BOUND engine's server — engine A's binary.
    #expect(box.recorded == [fixture.engineRoot.appendingPathComponent("bin/wineserver")])
    let readback = try await service.call(
        "wine.engines.selection", params: containerParam(fixture), workspace: fixture.workspace
    )
    #expect(readback.object?["engineID"] == .string(idB))
}

/// A live wineserver probe refuses the rebind and keeps the binding.
@Test @MainActor func runningWineserverBlocksReselection() async throws {
    let fixture = try EngineFixture()
    defer { fixture.remove() }
    let service = engineService(fixture: fixture)
    let replyA = try await service.call(
        "wine.engines.register",
        params: ["path": .string(fixture.engineRoot.path)],
        workspace: fixture.workspace
    )
    let idA = try #require(replyA.object?["id"]?.string)
    let rootB = fixture.root.appendingPathComponent("EngineB")
    try EngineFixture.makeEngine(at: rootB)
    let replyB = try await service.call(
        "wine.engines.register",
        params: ["path": .string(rootB.path)],
        workspace: fixture.workspace
    )
    let idB = try #require(replyB.object?["id"]?.string)

    var params = containerParam(fixture)
    params["id"] = .string(idA)
    try await withIdleWineProbes {
        _ = try await service.call("wine.engines.select", params: params, workspace: fixture.workspace)
    }

    params["id"] = .string(idB)
    do {
        let serverRunning: @Sendable (URL, URL) async throws -> Bool = { _, _ in true }
        try await withIdleWineProbes(probe: serverRunning) {
            _ = try await service.call(
                "wine.engines.select", params: params, workspace: fixture.workspace
            )
        }
        Issue.record("selecting over a live wineserver must fail")
    } catch let error as BridgeFailure {
        #expect(error.code == "container_busy")
    }
    // An indeterminate probe outcome fails closed the same way.
    do {
        let probeTimedOut: @Sendable (URL, URL) async throws -> Bool = { _, _ in
            throw WineProcessQueryFailurePlaceholder.timedOut
        }
        try await withIdleWineProbes(probe: probeTimedOut) {
            _ = try await service.call(
                "wine.engines.select", params: params, workspace: fixture.workspace
            )
        }
        Issue.record("selecting with an unknown wineserver state must fail")
    } catch let error as BridgeFailure {
        #expect(error.code == "container_busy")
    }
    let readback = try await service.call(
        "wine.engines.selection", params: containerParam(fixture), workspace: fixture.workspace
    )
    #expect(readback.object?["engineID"] == .string(idA))
}

/// Missing bound engine recovery path: the host-wide probe decides. An
/// unknown or busy host state refuses; a confirmed-idle host allows rebind.
@Test @MainActor func missingBoundEngineRecoveryUsesHostProbe() async throws {
    let fixture = try EngineFixture()
    defer { fixture.remove() }
    let service = engineService(fixture: fixture)
    let replyA = try await service.call(
        "wine.engines.register",
        params: ["path": .string(fixture.engineRoot.path)],
        workspace: fixture.workspace
    )
    let idA = try #require(replyA.object?["id"]?.string)
    let rootB = fixture.root.appendingPathComponent("EngineB")
    try EngineFixture.makeEngine(at: rootB)
    let replyB = try await service.call(
        "wine.engines.register",
        params: ["path": .string(rootB.path)],
        workspace: fixture.workspace
    )
    let idB = try #require(replyB.object?["id"]?.string)

    var params = containerParam(fixture)
    params["id"] = .string(idA)
    try await withIdleWineProbes {
        _ = try await service.call("wine.engines.select", params: params, workspace: fixture.workspace)
    }
    try FileManager.default.removeItem(at: fixture.engineRoot)

    params["id"] = .string(idB)
    // Host observation says something Wine-ish still runs -> refuse.
    do {
        let hostBusy: @Sendable () async throws -> Bool = { true }
        try await Wine.$anyWineserverRunning.withValue(hostBusy) {
            _ = try await service.call(
                "wine.engines.select", params: params, workspace: fixture.workspace
            )
        }
        Issue.record("rebind while a host wineserver runs must fail")
    } catch let error as BridgeFailure {
        #expect(error.code == "container_busy")
    }
    // Host observation itself is unknown -> still refuse.
    do {
        let hostUnknown: @Sendable () async throws -> Bool = {
            throw WineProcessQueryFailurePlaceholder.timedOut
        }
        try await Wine.$anyWineserverRunning.withValue(hostUnknown) {
            _ = try await service.call(
                "wine.engines.select", params: params, workspace: fixture.workspace
            )
        }
        Issue.record("rebind with unknown host state must fail")
    } catch let error as BridgeFailure {
        #expect(error.code == "container_busy")
    }
    // Confirmed idle -> the recovery rebind is allowed.
    let hostIdle: @Sendable () async throws -> Bool = { false }
    try await Wine.$anyWineserverRunning.withValue(hostIdle) {
        _ = try await service.call(
            "wine.engines.select", params: params, workspace: fixture.workspace
        )
    }
    let readback = try await service.call(
        "wine.engines.selection", params: containerParam(fixture), workspace: fixture.workspace
    )
    #expect(readback.object?["engineID"] == .string(idB))
}

/// An arbitrary error for the injected host probe.
private enum WineProcessQueryFailurePlaceholder: Error {
    case timedOut
}

@Test @MainActor func featureOverrideFlow() async throws {
    let fixture = try EngineFixture()
    defer { fixture.remove() }
    let service = engineService(fixture: fixture)
    let registered = try await service.call(
        "wine.engines.register",
        params: ["path": .string(fixture.engineRoot.path)],
        workspace: fixture.workspace
    )
    let id = try #require(registered.object?["id"]?.string)
    let fingerprint = try #require(registered.object?["fingerprint"]?.string)
    var select = containerParam(fixture)
    select["id"] = .string(id)
    try await withIdleWineProbes {
        _ = try await service.call(
            "wine.engines.select", params: select, workspace: fixture.workspace
        )
    }

    func override(_ extra: [String: JSONValue]) -> [String: JSONValue] {
        var params = containerParam(fixture)
        params["feature"] = .string("msync")
        params.merge(extra) { _, new in new }
        return params
    }

    // Unverified feature without confirmation → refused.
    do {
        _ = try await service.call(
            "wine.engines.setFeatureOverride",
            params: override(["enabled": .bool(true)]),
            workspace: fixture.workspace
        )
        Issue.record("unconfirmed unverified feature must be refused")
    } catch let error as BridgeFailure {
        #expect(error.code == "confirmation_required")
    }

    // Confirmation with a stale fingerprint → refused.
    do {
        _ = try await service.call(
            "wine.engines.setFeatureOverride",
            params: override([
                "enabled": .bool(true),
                "confirmed": .bool(true),
                "fingerprint": .string("stale")
            ]),
            workspace: fixture.workspace
        )
        Issue.record("stale fingerprint must be refused")
    } catch let error as BridgeFailure {
        #expect(error.code == "stale_fingerprint")
    }

    // Confirmation bound to the current fingerprint → approved.
    let approved = try await service.call(
        "wine.engines.setFeatureOverride",
        params: override([
            "enabled": .bool(true),
            "confirmed": .bool(true),
            "fingerprint": .string(fingerprint)
        ]),
        workspace: fixture.workspace
    )
    let msync = approved.object?["features"]?.array?
        .first { $0.object?["id"] == .string("msync") }
    #expect(msync?.object?["enabled"] == .bool(true))
    #expect(approved.object?["featureOverrides"]?.object?["msync"] == .string(fingerprint))

    // Unavailable feature (no DXVK payload) can never be confirmed on.
    do {
        var params = containerParam(fixture)
        params["feature"] = .string("dxvk")
        params["enabled"] = .bool(true)
        params["confirmed"] = .bool(true)
        params["fingerprint"] = .string(fingerprint)
        _ = try await service.call(
            "wine.engines.setFeatureOverride", params: params, workspace: fixture.workspace
        )
        Issue.record("unavailable feature must not be confirmable")
    } catch let error as BridgeFailure {
        #expect(error.code == "feature_unavailable")
    }

    // Unknown feature id → invalid params.
    do {
        var params = containerParam(fixture)
        params["feature"] = .string("not-a-feature")
        _ = try await service.call(
            "wine.engines.setFeatureOverride", params: params, workspace: fixture.workspace
        )
        Issue.record("unknown feature must be refused")
    } catch let error as BridgeFailure {
        #expect(error.code == "invalid_params")
    }

    // Disabling removes the approval again.
    let cleared = try await service.call(
        "wine.engines.setFeatureOverride",
        params: override(["enabled": .bool(false)]),
        workspace: fixture.workspace
    )
    #expect(cleared.object?["featureOverrides"]?.object?["msync"] == nil)
}

@Test @MainActor func fieldPolicyFollowsDependencyChain() async throws {
    let fixture = try EngineFixture()
    defer { fixture.remove() }
    // Engine with a complete DXVK payload: `dxvk` and `dxvkAsync` are both
    // unverified, `dxvkAsync` depends on `dxvk`.
    let dxvkRoot = fixture.root.appendingPathComponent("EngineDXVK")
    try EngineFixture.makeEngine(at: dxvkRoot, dxvk: true)
    let service = engineService(fixture: fixture)
    let registered = try await service.call(
        "wine.engines.register",
        params: ["path": .string(dxvkRoot.path)],
        workspace: fixture.workspace
    )
    let id = try #require(registered.object?["id"]?.string)
    let fingerprint = try #require(registered.object?["fingerprint"]?.string)
    var select = containerParam(fixture)
    select["id"] = .string(id)
    try await withIdleWineProbes {
        _ = try await service.call(
            "wine.engines.select", params: select, workspace: fixture.workspace
        )
    }

    func fieldPolicy() async throws -> [String: JSONValue] {
        let selection = try await service.call(
            "wine.engines.selection",
            params: containerParam(fixture),
            workspace: fixture.workspace
        )
        return try #require(selection.object?["fieldPolicy"]?.object)
    }

    // Child-before-parent: gating `dxvkAsync` surfaces the unmet `dxvk`
    // parent — the next confirmation approves dxvk, not dxvkAsync again.
    var policy = try await fieldPolicy()
    var dxvkAsync = try #require(policy["dxvkAsync"]?.object)
    #expect(dxvkAsync["disabled"] == .bool(true))
    #expect(dxvkAsync["feature"] == .string("dxvk"))
    #expect(dxvkAsync["canOverride"] == .bool(true))

    // Approving the parent: dxvkAsync itself becomes the blocker — its own
    // approval is still required, the parent's is not re-asked.
    var approve = containerParam(fixture)
    approve["feature"] = .string("dxvk")
    approve["enabled"] = .bool(true)
    approve["confirmed"] = .bool(true)
    approve["fingerprint"] = .string(fingerprint)
    _ = try await service.call(
        "wine.engines.setFeatureOverride", params: approve, workspace: fixture.workspace
    )
    policy = try await fieldPolicy()
    dxvkAsync = try #require(policy["dxvkAsync"]?.object)
    #expect(dxvkAsync["disabled"] == .bool(true))
    #expect(dxvkAsync["feature"] == .string("dxvkAsync"))

    // Once both are approved the field unlocks.
    approve["feature"] = .string("dxvkAsync")
    _ = try await service.call(
        "wine.engines.setFeatureOverride", params: approve, workspace: fixture.workspace
    )
    policy = try await fieldPolicy()
    dxvkAsync = try #require(policy["dxvkAsync"]?.object)
    #expect(dxvkAsync["disabled"] == .bool(false))
}

@Test @MainActor func fieldPolicyNeuralChoiceChainsTwoApprovals() async throws {
    let fixture = try EngineFixture()
    defer { fixture.remove() }
    // Bare engine: gdiUpscaling is unverified, gdiCoreML has no payload so
    // it is unavailable — neural choices must report unavailable and NOT
    // confirmable even though gdiUpscaling itself is.
    let service = engineService(fixture: fixture)
    let registered = try await service.call(
        "wine.engines.register",
        params: ["path": .string(fixture.engineRoot.path)],
        workspace: fixture.workspace
    )
    let id = try #require(registered.object?["id"]?.string)
    var select = containerParam(fixture)
    select["id"] = .string(id)
    try await withIdleWineProbes {
        _ = try await service.call(
            "wine.engines.select", params: select, workspace: fixture.workspace
        )
    }

    let selection = try await service.call(
        "wine.engines.selection", params: containerParam(fixture), workspace: fixture.workspace
    )
    let policy = try #require(selection.object?["fieldPolicy"]?.object)
    let upscaler = try #require(policy["gdiUpscaler"]?.object)
    let choices = try #require(upscaler["choices"]?.object)

    // Non-neural choice: only gdiUpscaling gates it — confirmable.
    let anime4k = try #require(choices["anime4k"]?.object)
    #expect(anime4k["disabled"] == .bool(true))
    #expect(anime4k["state"] == .string("unverified"))
    #expect(anime4k["canOverride"] == .bool(true))
    #expect(anime4k["feature"] == .string("gdiUpscaling"))

    // Neural choice: the missing CoreML payload makes it hard-unavailable —
    // no confirmation affordance.
    let realcugan = try #require(choices["realcugan"]?.object)
    #expect(realcugan["disabled"] == .bool(true))
    #expect(realcugan["state"] == .string("unavailable"))
    #expect(realcugan["canOverride"] == .bool(false))
    #expect(realcugan["feature"] == .string("gdiCoreML"))
}

@Test @MainActor func removeRejectsManagedAndReferencedEngines() async throws {
    let fixture = try EngineFixture()
    defer { fixture.remove() }
    let referenced = ReferencedIDs()
    let service = engineService(fixture: fixture) { referenced.ids }

    do {
        _ = try await service.call(
            "wine.engines.remove",
            params: ["id": .string(WineEngine.managedID)],
            workspace: fixture.workspace
        )
        Issue.record("removing the managed engine must fail")
    } catch let error as BridgeFailure {
        #expect(error.code == "managed_immutable")
    }

    let registered = try await service.call(
        "wine.engines.register",
        params: ["path": .string(fixture.engineRoot.path)],
        workspace: fixture.workspace
    )
    let id = try #require(registered.object?["id"]?.string)
    referenced.ids.insert(id)
    do {
        _ = try await service.call(
            "wine.engines.remove",
            params: ["id": .string(id)],
            workspace: fixture.workspace
        )
        Issue.record("removing an in-use engine must fail")
    } catch let error as BridgeFailure {
        #expect(error.code == "engine_in_use")
    }

    referenced.ids.removeAll()
    let removed = try await service.call(
        "wine.engines.remove", params: ["id": .string(id)], workspace: fixture.workspace
    )
    #expect(removed.object?["removed"] == .bool(true))
    // Removal never deletes the engine tree itself.
    #expect(FileManager.default.fileExists(atPath: fixture.engineRoot.path))
}

@Test @MainActor func wineDisabledDeniesEngineMethods() async throws {
    let fixture = try EngineFixture()
    defer { fixture.remove() }
    let service = engineService(fixture: fixture, wineEnabled: false)

    #expect(!service.methods.contains("wine.engines.list"))
    do {
        _ = try await service.call("wine.engines.list", params: [:], workspace: fixture.workspace)
        Issue.record("engine methods must be unavailable without --enable-wine")
    } catch let error as BridgeFailure {
        #expect(error.code == "method_unavailable")
    }
}

@Test @MainActor func missingSelectedEngineStaysReadable() async throws {
    let fixture = try EngineFixture()
    defer { fixture.remove() }
    let service = engineService(fixture: fixture)
    let registered = try await service.call(
        "wine.engines.register",
        params: ["path": .string(fixture.engineRoot.path)],
        workspace: fixture.workspace
    )
    let id = try #require(registered.object?["id"]?.string)
    var params = containerParam(fixture)
    params["id"] = .string(id)
    try await withIdleWineProbes {
        _ = try await service.call("wine.engines.select", params: params, workspace: fixture.workspace)
    }

    // The engine tree vanishes out from under a still-bound registration;
    // the selection must stay readable so recovery to another engine is
    // possible. Public `wine.engines.remove` rightly refuses while a bottle
    // is bound — an external delete is the scenario recovery handles.
    try FileManager.default.removeItem(at: fixture.engineRoot)
    let selection = try await service.call(
        "wine.engines.selection", params: containerParam(fixture), workspace: fixture.workspace
    )
    #expect(selection.object?["engineID"] == .string(id))
    #expect(selection.object?["engine"]?.object?["available"] == .bool(false))
    #expect(selection.object?["engine"]?.object?["error"]?.string != nil)
}

@Test @MainActor func createWithEngineIDPersistsExternalBinding() async throws {
    let fixture = try EngineFixture()
    defer { fixture.remove() }
    let service = engineService(fixture: fixture)
    let registered = try await service.call(
        "wine.engines.register",
        params: ["path": .string(fixture.engineRoot.path)],
        workspace: fixture.workspace
    )
    let id = try #require(registered.object?["id"]?.string)

    let parent = fixture.root.appendingPathComponent("Parents")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let started = try await service.call(
        "bottle.create",
        params: [
            "name": .string("ExternalBottle"),
            "parent": .string(parent.path),
            "windowsVersion": .string("win10"),
            "engineID": .string(id)
        ],
        workspace: fixture.workspace
    )
    let jobID = try #require(started.object?["jobID"]?.string)
    var result: JSONValue?
    for _ in 0 ..< 600 {
        let record = try service.jobs.call("jobs.get", params: ["jobID": .string(jobID)])
        if record.object?["status"]?.string == "completed" {
            result = record.object?["result"]
            break
        }
        if record.object?["status"]?.string == "failed" {
            Issue.record("bottle.create failed: \(record.object?["error"] ?? .null)")
            break
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    let path = try #require(result?.object?["path"]?.string)
    let readback = try await service.call(
        "wine.engines.selection",
        params: ["container": .string(path)],
        workspace: fixture.workspace
    )
    #expect(readback.object?["engineID"] == .string(id))
}

@Test @MainActor func createWithUnknownEngineFailsWithoutDirectory() async throws {
    let fixture = try EngineFixture()
    defer { fixture.remove() }
    let service = engineService(fixture: fixture)
    let parent = fixture.root.appendingPathComponent("Parents")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

    let started = try await service.call(
        "bottle.create",
        params: [
            "name": .string("Doomed"),
            "parent": .string(parent.path),
            "windowsVersion": .string("win10"),
            "engineID": .string("ghost-engine")
        ],
        workspace: fixture.workspace
    )
    let jobID = try #require(started.object?["jobID"]?.string)
    var failed = false
    for _ in 0 ..< 200 {
        let record = try service.jobs.call("jobs.get", params: ["jobID": .string(jobID)])
        if record.object?["status"]?.string == "failed" {
            failed = true
            break
        }
        if record.object?["status"]?.string == "completed" {
            break
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(failed)
    // Engine resolution happens before the destination directory exists.
    let contents = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
    #expect(contents.isEmpty)
}

/// Mutable box for the `@Sendable` referenced-id closure.
private final class ReferencedIDs: @unchecked Sendable {
    var ids = Set<String>()
}

/// Lets a test park a job so `hasLifecycleOperation` stays true until opened.
private actor JobGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        if opened {
            return
        }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}
