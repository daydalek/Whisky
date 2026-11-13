//
//  LinuxApplicationServices+Engines.swift
//  WhiskyApplication
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
import WhiskyBridgeProtocol
import WhiskyCore

extension LinuxApplicationServices {
    static let engineMethods = [
        "wine.engines.list",
        "wine.engines.register",
        "wine.engines.remove",
        "wine.engines.selection",
        "wine.engines.select",
        "wine.engines.setFeatureOverride"
    ]

    func callEngineMethod(
        _ method: String,
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) async throws -> JSONValue {
        guard let engineStore else {
            throw BridgeFailure("method_unavailable", "Wine engine management is unavailable")
        }
        switch method {
        case "wine.engines.list":
            let result = engineStore.list()
            return .object([
                "engines": .array(result.engines.map { $0.record() }),
                "loadError": result.loadError.map(JSONValue.string) ?? .null
            ])

        case "wine.engines.register":
            let path = try params.path("path")
            let name = params["name"]?.string
            do {
                let engine = try engineStore.register(at: path, name: name)
                return engine.record()
            } catch let error as LinuxWineEngineError {
                throw BridgeFailure("engine_rejected", error.localizedDescription)
            } catch let error as LinuxWineEngineStoreError {
                throw mapStoreError(error)
            }

        case "wine.engines.remove":
            let id = try params.text("id")
            let containers = try workspace.containers()
            let lease: LinuxWineEngineLease? = id == LinuxWineEngine.managedID
                ? nil
                : try engineStore.acquireExclusiveLease(for: id)
            defer { lease?.release() }
            do {
                try engineStore.remove(id: id) { targetID in
                    containers.contains { containerReferencesEngine($0, engineID: targetID) }
                }
                return .object(["removed": .bool(true)])
            } catch let error as LinuxWineEngineStoreError {
                throw mapStoreError(error)
            }

        case "wine.engines.selection":
            let container = try workspace.resolve(params)
            return try engineSelection(for: container, store: engineStore)

        case "wine.engines.select":
            let container = try workspace.resolve(params)
            let targetID = try params.text("id")
            return try await selectEngine(id: targetID, for: container, store: engineStore)

        case "wine.engines.setFeatureOverride":
            let container = try workspace.resolve(params)
            let featureRaw = try params.text("feature")
            guard let feature = LinuxWineEngineFeature(rawValue: featureRaw) else {
                throw BridgeFailure("invalid_params", "Unknown Wine engine feature '\(featureRaw)'")
            }
            let enabled = params["enabled"] == nil ? true : try params.flag("enabled")
            let confirmed = params["confirmed"] == nil ? false : try params.flag("confirmed")
            let fingerprint = params["fingerprint"]?.string
            return try await setFeatureOverride(
                feature: feature,
                enabled: enabled,
                confirmed: confirmed,
                expectedFingerprint: fingerprint,
                for: container,
                store: engineStore
            )

        default:
            throw BridgeFailure("method_unavailable", "Unknown Wine engine method")
        }
    }

    // MARK: - Selection, confirmation & reference checks

    private func engineSelection(
        for container: URL,
        store: LinuxWineEngineStore
    ) throws -> JSONValue {
        let binding = try readBinding(for: container)
        let engine = store.lookupDescriptor(id: binding.engineID)
        return selectionPayload(engineID: binding.engineID, engine: engine, overrides: binding.featureOverrides)
    }

    private func selectEngine(
        id targetID: String,
        for container: URL,
        store: LinuxWineEngineStore
    ) async throws -> JSONValue {
        let target: LinuxWineEngine
        do {
            target = try store.resolve(id: targetID)
        } catch let error as LinuxWineEngineStoreError {
            throw mapStoreError(error)
        }

        let file = ConfigurationFile(url: container.appendingPathComponent("Metadata.plist"), locking: HostFileLock())
        let currentBinding = try readBinding(for: container)

        // Lock distinct engines in canonical order so two concurrent switches
        // between engines A and B never deadlock each other.
        let leaseIDs = currentBinding.engineID == target.id
            ? [target.id]
            : [currentBinding.engineID, target.id].sorted()
        var leases: [LinuxWineEngineLease] = []
        defer {
            for lease in leases.reversed() {
                lease.release()
            }
        }
        for leaseID in leaseIDs {
            try leases.append(store.acquireExclusiveLease(for: leaseID))
        }

        if let runtimeService, runtimeService.containerIsBusy(container) {
            throw BridgeFailure(
                "container_busy",
                "Stop running programs in this container before switching its Wine engine",
                retryable: true
            )
        }

        let env = store.environment
        let currentEngine = store.lookupDescriptor(id: currentBinding.engineID)
        if let currentHost = currentEngine.makeHost(environment: env), currentHost.canExecute {
            try await ensureWineserverIdle(host: currentHost, container: container)
        }
        if target.id != currentEngine.id,
           let targetHost = target.makeHost(environment: env), targetHost.canExecute {
            try await ensureWineserverIdle(host: targetHost, container: container)
        }

        // Clearing overrides on rebind mirrors macOS: confirmations belong
        // strictly to the engine fingerprint they were granted for.
        try await file.updateWineEngineBinding(engineID: target.id, featureOverrides: [:])
        return selectionPayload(engineID: target.id, engine: target, overrides: [:])
    }

    private func setFeatureOverride(
        feature: LinuxWineEngineFeature,
        enabled: Bool,
        confirmed: Bool,
        expectedFingerprint: String?,
        for container: URL,
        store: LinuxWineEngineStore
    ) async throws -> JSONValue {
        let file = ConfigurationFile(url: container.appendingPathComponent("Metadata.plist"), locking: HostFileLock())
        let binding = try readBinding(for: container)
        let lease = try store.acquireExclusiveLease(for: binding.engineID)
        defer { lease.release() }

        let engine: LinuxWineEngine
        do {
            engine = try store.resolve(id: binding.engineID)
        } catch let error as LinuxWineEngineStoreError {
            throw mapStoreError(error)
        }

        var overrides = binding.featureOverrides
        if enabled {
            guard confirmed else {
                throw BridgeFailure(
                    "unverified",
                    "Explicit user confirmation is required before enabling \(feature.rawValue)"
                )
            }
            let status = engine.featureStatus(feature)
            switch status.state {
            case .unavailable:
                throw BridgeFailure(
                    "engine_unavailable",
                    status.reason ?? "\(feature.rawValue) is not available on this Wine engine"
                )
            case .supported:
                break
            case .unverified:
                guard status.canOverride else {
                    throw BridgeFailure(
                        "engine_unavailable",
                        status.reason ?? "\(feature.rawValue) cannot be overridden on this Wine engine"
                    )
                }
                guard let fingerprint = engine.fingerprint, !fingerprint.isEmpty else {
                    throw BridgeFailure(
                        "engine_unavailable",
                        "Cannot verify engine fingerprint for \(feature.rawValue)"
                    )
                }
                if let expectedFingerprint, expectedFingerprint != fingerprint {
                    throw BridgeFailure(
                        "fingerprint_mismatch",
                        "This Wine engine changed on disk; reopen settings and confirm again"
                    )
                }
                overrides[feature.rawValue] = fingerprint
            }
        } else {
            overrides.removeValue(forKey: feature.rawValue)
        }

        try await file.updateWineEngineBinding(engineID: binding.engineID, featureOverrides: overrides)
        return selectionPayload(engineID: binding.engineID, engine: engine, overrides: overrides)
    }

    private func ensureWineserverIdle(host: LinuxWineHost, container: URL) async throws {
        let running: Bool
        do {
            running = try await wineserverProbe(host, container)
        } catch {
            throw BridgeFailure(
                "wineserver_unknown",
                "Could not confirm wineserver state for this container before switching engines: \(error.localizedDescription)",
                retryable: true
            )
        }
        if running {
            throw BridgeFailure(
                "wineserver_running",
                "Wait for all Wine background processes in this container to exit before switching engines",
                retryable: true
            )
        }
    }

    private func selectionPayload(
        engineID: String,
        engine: LinuxWineEngine,
        overrides: [String: String]
    ) -> JSONValue {
        .object([
            "engineID": .string(engineID),
            "engine": engine.record(),
            "featureOverrides": .object(overrides.mapValues(JSONValue.string)),
            "features": .array(engine.features.map { status in
                let eff = engine.effectiveState(for: status.feature, overrides: overrides)
                return .object([
                    "id": .string(status.feature.rawValue),
                    "state": .string(eff.state.rawValue),
                    "reason": eff.reason.map(JSONValue.string) ?? .null,
                    "canOverride": .bool(eff.canOverride),
                    "enabled": .bool(eff.enabled)
                ])
            }),
            "fieldPolicy": .object(engine.fieldPolicy(overrides: overrides))
        ])
    }

    private func containerReferencesEngine(_ container: URL, engineID: String) -> Bool {
        // Conservatively block removal if a registered container's metadata
        // cannot be read, mirroring macOS's `containerReferencesEngine`.
        guard let binding = try? readBinding(for: container) else {
            return true
        }
        return binding.engineID == engineID
    }

    func containerUsesManagedEngine(_ container: URL) -> Bool {
        guard let binding = try? readBinding(for: container) else {
            return true
        }
        return binding.engineID == LinuxWineEngine.managedID
    }

    private func readBinding(for container: URL) throws -> (engineID: String, featureOverrides: [String: String]) {
        try ConfigurationFile.wineEngineBinding(at: container.appendingPathComponent("Metadata.plist"))
    }

    private func mapStoreError(_ error: LinuxWineEngineStoreError) -> BridgeFailure {
        switch error {
        case .managedImmutable:
            BridgeFailure("managed_immutable", error.localizedDescription)
        case .unknownEngine:
            BridgeFailure("unknown_engine", error.localizedDescription)
        case .engineInUse:
            BridgeFailure("engine_in_use", error.localizedDescription)
        case .engineUnavailable:
            BridgeFailure("engine_unavailable", error.localizedDescription)
        case .corruptRegistry:
            BridgeFailure("operation_failed", error.localizedDescription)
        }
    }
}
