//
//  MacOSApplicationServices+Engines.swift
//  WhiskyNativeBridge
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
import WhiskyApplication
import WhiskyBridgeProtocol
import WhiskyCore
import WhiskyKit

// MARK: - Custom Wine engines

extension MacOSApplicationServices {
    /// `wine.engines.*` — registration, per-container selection and the
    /// explicit feature-confirmation flow for external engines. Everything
    /// here is macOS-only and gated by `--enable-wine`, matching the other
    /// Wine host effects.
    func wineEnginesCall(
        _ method: String,
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) async throws -> JSONValue {
        switch method {
        case "wine.engines.list":
            return .object([
                "engines": .array(engineStore.list().map(Self.engineRecord)),
                "loadError": engineStore.lastLoadError.map {
                    .string($0.errorDescription ?? "registry error")
                } ?? .null
            ])
        case "wine.engines.register":
            let path = try params.path("path")
            let name = params["name"]?.string
            do {
                return try Self.engineRecord(engineStore.register(at: path, name: name))
            } catch let error as WineEngineError {
                throw BridgeFailure("engine_rejected", error.errorDescription ?? "Engine rejected")
            }
        case "wine.engines.remove":
            return try removeEngine(id: params.text("id"), workspace: workspace)
        case "wine.engines.selection":
            return try engineSelection(container: resolveEngineContainer(params, workspace: workspace))
        case "wine.engines.select":
            return try await selectEngine(
                params.text("id"), params: params, workspace: workspace
            )
        case "wine.engines.setFeatureOverride":
            return try await setFeatureOverride(params, workspace: workspace)
        default:
            throw BridgeFailure("method_unavailable", "Native method is unavailable")
        }
    }

    /// One engine as a wire record. `features` carries the per-feature
    /// status the UI uses to render disabled choices with reasons.
    static func engineRecord(_ engine: WineEngine) -> JSONValue {
        .object([
            "id": .string(engine.id),
            "name": .string(engine.name),
            "path": .string(engine.rootURL.path),
            "managed": .bool(engine.isManaged),
            "available": .bool(engine.isAvailable),
            "error": engine.availabilityError.map { .string($0) } ?? .null,
            "architectures": .array(engine.architectures.map { .string($0) }),
            "fingerprint": engine.isManaged || engine.fingerprint.isEmpty
                ? .null : .string(engine.fingerprint),
            "version": engine.version.map { .string($0) } ?? .null,
            "features": .array(engine.featureStatuses().map(featureRecord))
        ])
    }

    private static func featureRecord(_ status: WineEngineFeatureStatus) -> JSONValue {
        .object([
            "id": .string(status.feature.rawValue),
            "state": .string(status.state.rawValue),
            "reason": status.reason.map { .string($0) } ?? .null,
            "canOverride": .bool(status.canOverride)
        ])
    }

    /// Engine record for a bound id that is no longer in the registry —
    /// keeps the selection readable so the UI can reassign instead of
    /// crashing on a stale bottle.
    private static func unavailableRecord(id: String, error: String) -> JSONValue {
        .object([
            "id": .string(id),
            "name": .string(id),
            "path": .string(""),
            "managed": .bool(false),
            "available": .bool(false),
            "error": .string(error),
            "architectures": .array([]),
            "fingerprint": .null,
            "version": .null,
            "features": .array(WineEngineFeature.allCases.map { feature in
                featureRecord(WineEngineFeatureStatus(
                    feature: feature, state: .unavailable, reason: error
                ))
            })
        ])
    }

    /// `wine.engines.selection` / the shared return value of the mutating
    /// calls: the bound engine (record included even when unavailable), the
    /// persisted confirmations, per-feature effective state and the
    /// field/choice policy the schema-driven UI needs.
    private func engineSelection(container: URL) throws -> JSONValue {
        guard let bottle = bottle(container) else { throw BridgeFailure(
            "invalid_container",
            "Wine settings are unreadable"
        ) }
        let engineID = bottle.settings.wineEngineID
        let overrides = bottle.settings.wineFeatureOverrides
        let engine = try? engineStore.resolve(id: engineID)

        let features: [JSONValue]
        if let engine {
            features = engine.featureStatuses().map { status in
                .object([
                    "id": .string(status.feature.rawValue),
                    "state": .string(status.state.rawValue),
                    "reason": status.reason.map { .string($0) } ?? .null,
                    "canOverride": .bool(status.canOverride),
                    "enabled": .bool(engine.isFeatureEnabled(status.feature, overrides: overrides))
                ])
            }
        } else {
            let message = "The selected Wine engine is missing or unavailable"
            features = WineEngineFeature.allCases.map { feature in
                .object([
                    "id": .string(feature.rawValue),
                    "state": .string("unavailable"),
                    "reason": .string(message),
                    "canOverride": .bool(false),
                    "enabled": .bool(false)
                ])
            }
        }

        return .object([
            "engineID": .string(engineID),
            "engine": engine.map(Self.engineRecord) ?? Self.unavailableRecord(
                id: engineID, error: "The selected Wine engine is not registered or no longer usable"
            ),
            "featureOverrides": .object(overrides.mapValues { .string($0) }),
            "features": .array(features),
            "fieldPolicy": .object(Self.fieldPolicy(engine: engine, overrides: overrides))
        ])
    }

    /// Canonicalizes a `container` param through the workspace: the path must
    /// name a registered container, so an engine mutation can never target an
    /// arbitrary directory the frontend typed.
    private func resolveEngineContainer(
        _ params: [String: JSONValue], workspace: ApplicationWorkspace
    ) throws -> URL {
        do {
            return try workspace.resolve(params)
        } catch let error as BridgeFailure {
            throw BridgeFailure("invalid_container", error.message)
        }
    }

    /// `wine.engines.remove`. References come from the live workspace — every
    /// registered container's metadata is read now, and a container whose
    /// metadata cannot be read counts as a reference — so removal fails
    /// closed rather than orphaning a binding it cannot see.
    private func removeEngine(id: String, workspace: ApplicationWorkspace) throws -> JSONValue {
        // Managed is immutable regardless of what any container binds.
        if id == WineEngine.managedID {
            throw BridgeFailure(
                "managed_immutable",
                "The managed runtime is not a removable engine registration"
            )
        }
        let containers: [URL]
        do {
            containers = try workspace.containers()
        } catch {
            throw BridgeFailure(
                "engine_in_use",
                "The container registry cannot be read, so engine references cannot be proven absent"
            )
        }
        for container in containers where containerReferencesEngine(container, engineID: id) {
            throw BridgeFailure(
                "engine_in_use",
                "A bottle is bound to this engine. Rebind it first — engine records are never orphaned."
            )
        }
        // The store's own check still applies: metadata outside this
        // workspace (legacy roots, other workspaces) can hold the reference.
        do {
            try engineStore.remove(id: id)
        } catch let error as WineEngineError {
            throw BridgeFailure(Self.engineErrorCode(error), error.errorDescription ?? "Remove failed")
        }
        return .object(["removed": .bool(true)])
    }

    /// Whether `container`'s metadata binds `engineID` — conservatively
    /// `true` when the metadata cannot be read at all.
    private func containerReferencesEngine(_ container: URL, engineID: String) -> Bool {
        let metadata = container.appendingPathComponent("Metadata.plist")
        guard let data = try? ApplicationWorkspace.read(metadata),
              let settings = try? PropertyListDecoder().decode(BottleSettings.self, from: data)
        else {
            return true
        }
        return settings.wineEngineID == engineID
    }

    /// Maps configuration fields (and individual choices) to disabled state
    /// with a reason. Anything not listed is unrestricted — basic settings
    /// like the Windows version stay editable on every engine.
    ///
    /// Keys are the real `ContainerConfiguration` field ids and choice values
    /// the schema-driven UI renders — never invented names.
    static func fieldPolicy(
        engine: WineEngine?,
        overrides: [String: String]
    ) -> [String: JSONValue] {
        func enabled(_ feature: WineEngineFeature) -> Bool {
            engine?.isFeatureEnabled(feature, overrides: overrides) ?? false
        }
        func status(of feature: WineEngineFeature) -> WineEngineFeatureStatus? {
            engine?.status(of: feature)
        }
        func choiceState(_ features: WineEngineFeature..., reason: String? = nil) -> JSONValue {
            // Only UNMET requirements block: an approved gdiUpscaling must
            // not stay the blocker of a neural choice forever — the next
            // confirmable prerequisite (gdiCoreML) takes its place. The
            // requirement list walks each feature's parent chain first, so
            // approving dxvkAsync surfaces its missing dxvk parent.
            var unmet: [WineEngineFeature] = []
            for feature in features {
                for requirement in WineEngine.featureRequirements(of: feature)
                    where !enabled(requirement) && !unmet.contains(requirement) {
                    unmet.append(requirement)
                }
            }
            if unmet.isEmpty {
                return .object([
                    "disabled": .bool(false),
                    "reason": .null,
                    "state": .string("supported"),
                    "canOverride": .bool(false),
                    "feature": .null
                ])
            }
            // A hard-missing prerequisite anywhere in the chain makes the
            // choice unavailable outright — nothing left to confirm.
            if let blocker = unmet.first(where: {
                status(of: $0)?.state == .unavailable
            }) {
                let blockerStatus = status(of: blocker)
                return .object([
                    "disabled": .bool(true),
                    "reason": .string(
                        reason ?? blockerStatus?.reason
                            ?? "The selected engine does not support this option"
                    ),
                    "state": .string("unavailable"),
                    "canOverride": .bool(false),
                    "feature": .string(blocker.rawValue)
                ])
            }
            // Every unmet prerequisite is unverified: the first one is the
            // feature the next confirmation approves.
            let blocker = unmet[0]
            let blockerStatus = status(of: blocker)
            return .object([
                "disabled": .bool(true),
                "reason": .string(
                    reason ?? blockerStatus?.reason
                        ?? "The selected engine does not support this option"
                ),
                "state": .string("unverified"),
                "canOverride": .bool(blockerStatus?.canOverride ?? false),
                "feature": .string(blocker.rawValue)
            ])
        }
        func field(_ feature: WineEngineFeature) -> JSONValue {
            choiceState(feature)
        }
        var policy: [String: JSONValue] = [
            "graphicsBackend": .object([
                "choices": .object([
                    "d3dMetal": choiceState(.d3dMetal),
                    "dxmt": choiceState(.dxmt),
                    "dxvk": choiceState(.dxvk)
                ])
            ]),
            "enhancedSync": .object([
                "choices": .object([
                    "esync": choiceState(.esync),
                    "msync": choiceState(.msync)
                ])
            ]),
            "dxvkAsync": field(.dxvkAsync),
            "dxvkHud": field(.dxvk),
            "avxEnabled": field(.avx),
            "gdiUpscaler": .object([
                "choices": .object([
                    // Shader/MetalFX algorithms need the upscaler only; the
                    // neural models additionally need the CoreML payload —
                    // `gdiCoreML` is no schema field, these choice ids are.
                    "metalfx": choiceState(.gdiUpscaling),
                    "anime4k": choiceState(.gdiUpscaling),
                    "realcugan": choiceState(.gdiUpscaling, .gdiCoreML),
                    "adaptive": choiceState(.gdiUpscaling, .gdiCoreML),
                    "realesrgan": choiceState(.gdiUpscaling, .gdiCoreML),
                    "adaptive-realesrgan": choiceState(.gdiUpscaling, .gdiCoreML),
                    "adaptive-anime4k": choiceState(.gdiUpscaling, .gdiCoreML),
                    "adaptive-anime4k-realesrgan": choiceState(.gdiUpscaling, .gdiCoreML)
                ])
            ]),
            "gdiUpscalerCache": .object([
                // Like the neural algorithms the cache models share their
                // weights with, caching needs the upscaler AND the CoreML
                // payload — the non-`off` choices disable; `off` stays
                // selectable so a saved value can always be reverted.
                "choices": .object([
                    "memory": choiceState(.gdiUpscaling, .gdiCoreML),
                    "persistent": choiceState(.gdiUpscaling, .gdiCoreML)
                ])
            ]),
            "gdiUpscalerExcludedRegions": field(.gdiUpscaling),
            "metalHud": field(.metal),
            "metal4Enabled": field(.metal),
            "metalTrace": field(.metal),
            "metalFX": field(.metalFX),
            "frameGeneration": field(.frameGeneration),
            "shadowImportedHostMemory": field(.shadowImportedHostMemory),
            "shaderCacheEnabled": field(.dxvk),
            "dxrEnabled": field(.metal),
            "metalValidation": field(.metal)
        ]
        // Managed-runtime compatibility fixes do not apply to external
        // engines at all; they are never confirmable there. The launcher
        // section fields are the real schema ids — env fixes and spoofing
        // exist for the managed build's quirks.
        if engine?.isManaged == false {
            let managedOnly = JSONValue.object([
                "disabled": .bool(true),
                "reason": .string("This compatibility fix only applies to the managed Whisky Wine runtime"),
                "state": .string("unavailable"),
                "canOverride": .bool(false),
                "feature": .null
            ])
            for fieldID in [
                "launcherCompatibilityMode", "launcherMode", "detectedLauncher",
                "launcherLocale", "gpuSpoofing", "gpuVendor", "autoEnableDXVK"
            ] {
                policy[fieldID] = managedOnly
            }
        }
        return policy
    }

    /// `wine.engines.select`. Holds the prefix's exclusive engine lease from
    /// before the busy checks until after the save, so a launch, a Winetricks
    /// run or another Maltoria process cannot interleave with the rebind —
    /// they take shared leases and are refused for the duration. Busy state
    /// is fail-closed on every layer: tracked runtime state, lifecycle jobs
    /// and a throwing wineserver probe all must say "idle".
    ///
    /// A bound engine that no longer resolves (its tree was deleted) cannot
    /// run a probe; that is the one recovery path, permitted only when no
    /// tracked session is active AND a conservative host-wide observation
    /// reports no wineserver at all. Nothing is ever killed to switch.
    private func selectEngine(
        _ id: String,
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) async throws -> JSONValue {
        let container = try resolveEngineContainer(params, workspace: workspace)
        guard let bottle = bottle(container) else { throw BridgeFailure(
            "invalid_container",
            "Wine settings are unreadable"
        ) }
        let engine: WineEngine
        do {
            engine = try engineStore.resolve(id: id)
        } catch let error as WineEngineError {
            throw BridgeFailure(Self.engineErrorCode(error), error.errorDescription ?? "Unknown engine")
        }
        guard engine.isAvailable else {
            throw BridgeFailure(
                "engine_unavailable",
                engine.availabilityError ?? "The selected Wine engine is not usable"
            )
        }

        let lease: Int32
        do {
            lease = try WineEngineLease.acquire(
                prefixURL: container, registryURL: engineStore.registryURL, exclusive: true
            )
        } catch let error as WineEngineError {
            throw BridgeFailure(
                Self.engineErrorCode(error),
                error.errorDescription ?? "The container is busy"
            )
        }
        defer { WineEngineLease.release(lease) }

        if jobs.hasLifecycleOperation || runtimeService.containerIsBusy(container) {
            throw BridgeFailure("container_busy", "Stop the container before changing its Wine engine")
        }

        if let bound = try? engineStore.resolve(id: bottle.settings.wineEngineID),
           bound.isAvailable {
            // The bound engine can answer for itself: any outcome other than
            // a clean "no server" — a running one, a wedged probe, a timeout —
            // refuses the rebind.
            let idle: Bool
            do {
                // Probe with THIS service's resolved descriptor, not a
                // re-resolution through the shared store.
                idle = try await !Wine.probeWineserver(for: bottle, engine: bound)
            } catch {
                throw BridgeFailure(
                    "container_busy",
                    "The bottle's Wineserver state could not be determined; not rebinding"
                )
            }
            guard idle else {
                throw BridgeFailure(
                    "container_busy", "Stop the container before changing its Wine engine"
                )
            }
        } else {
            // Recovery path only: the bound engine cannot run a probe, so the
            // host is checked conservatively — ANY wineserver blocks this.
            let hostIdle: Bool
            do {
                hostIdle = try await !Wine.anyWineserverRunning()
            } catch {
                throw BridgeFailure(
                    "container_busy",
                    "The host's Wineserver state could not be determined; not rebinding"
                )
            }
            guard hostIdle else {
                throw BridgeFailure(
                    "container_busy",
                    "A Wineserver is still running on this host; stop it before rebinding"
                )
            }
        }

        bottle.settings.wineEngineID = engine.id
        bottle.settings.wineFeatureOverrides = [:]
        bottle.saveBottleSettings()
        bottles[container] = nil
        return try engineSelection(container: container)
    }

    /// `wine.engines.setFeatureOverride`. Enabling an `unverified` feature
    /// needs `confirmed: true` and the engine's *current* fingerprint; a
    /// rebuilt or replaced engine invalidates the approval. `unavailable`
    /// features — missing payloads, a dead loader — can never be enabled.
    /// Disabling always removes the approval.
    ///
    /// The write is serialized with launches by the exclusive lease: an
    /// in-flight operation pinned its approval snapshot, so this change can
    /// never retroactively alter what it allowed.
    private func setFeatureOverride(
        _ params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) async throws -> JSONValue {
        let container = try resolveEngineContainer(params, workspace: workspace)
        guard let bottle = bottle(container) else { throw BridgeFailure(
            "invalid_container",
            "Wine settings are unreadable"
        ) }
        let featureID = try params.text("feature")
        guard let feature = WineEngineFeature(rawValue: featureID) else {
            throw BridgeFailure("invalid_params", "Unknown engine feature")
        }
        let enabled = params["enabled"]?.bool ?? true
        let engine: WineEngine
        do {
            engine = try engineStore.resolve(id: bottle.settings.wineEngineID)
        } catch let error as WineEngineError {
            throw BridgeFailure(Self.engineErrorCode(error), error.errorDescription ?? "Engine unavailable")
        }

        let lease: Int32
        do {
            lease = try WineEngineLease.acquire(
                prefixURL: container, registryURL: engineStore.registryURL, exclusive: true
            )
        } catch let error as WineEngineError {
            throw BridgeFailure(
                Self.engineErrorCode(error),
                error.errorDescription ?? "The container is busy"
            )
        }
        defer { WineEngineLease.release(lease) }

        var overrides = bottle.settings.wineFeatureOverrides
        if enabled {
            let status = engine.status(of: feature)
            switch status.state {
            case .unavailable:
                throw BridgeFailure(
                    "feature_unavailable",
                    status.reason ?? "This feature is unavailable on the selected engine"
                )
            case .unverified:
                guard status.canOverride else {
                    throw BridgeFailure(
                        "feature_unavailable",
                        status.reason ?? "This feature cannot be enabled"
                    )
                }
                guard params["confirmed"]?.bool == true else {
                    throw BridgeFailure("confirmation_required", "Explicit confirmation is required")
                }
                guard params["fingerprint"]?.string == engine.fingerprint, !engine.fingerprint.isEmpty else {
                    throw BridgeFailure(
                        "stale_fingerprint",
                        "The engine changed since this confirmation; confirm again"
                    )
                }
                overrides[feature.rawValue] = engine.fingerprint
            case .supported:
                // Already permitted — nothing to approve.
                break
            }
        } else {
            overrides.removeValue(forKey: feature.rawValue)
        }
        bottle.settings.wineFeatureOverrides = overrides
        bottle.saveBottleSettings()
        bottles[container] = nil
        return try engineSelection(container: container)
    }

    static func engineErrorCode(_ error: WineEngineError) -> String {
        switch error {
        case .managedImmutable: "managed_immutable"
        case .engineInUse: "engine_in_use"
        case .registryCorrupted: "registry_corrupted"
        case .unknownEngine: "unknown_engine"
        case .operationBusy: "container_busy"
        default: "engine_unavailable"
        }
    }
}
