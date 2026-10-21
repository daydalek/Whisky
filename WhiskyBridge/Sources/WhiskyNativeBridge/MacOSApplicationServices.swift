//
//  MacOSApplicationServices.swift
//  WhiskyCore
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

/// The helper publishes values; GPUI owns prompts and visual state.
@MainActor
public final class MacOSApplicationServices: NativeApplicationServices {
    private var bottles: [URL: (Data, Bottle)] = [:]
    private let wineEnabled: Bool
    private let jobs: BridgeJobStore
    private lazy var driver = WineLibraryRuntimeDriver(
        bottleResolver: { [weak self] in self?.bottle($0) },
        driverFactory: { MonitoredSteamClientDriver(bottle: $0) }
    )
    private lazy var runtimeService = RuntimeService(
        driver: driver,
        clipboard: { ClipboardManager.shared },
        policyLoader: { [weak self] containerURL in
            guard let bottle = self?.bottle(containerURL) else {
                throw BridgeFailure("invalid_container", "Wine settings are unreadable")
            }
            return (
                launcher: bottle.settings.detectedLauncher,
                policy: bottle.settings.clipboardPolicy,
                threshold: bottle.settings.clipboardThreshold
            )
        },
        beforeLaunch: { [weak self] entry in
            // Re-read program settings after edits performed through the portable service.
            self?.bottles[entry.bottleURL] = nil
        }
    )

    public init(wineEnabled: Bool, preferencesDomain: String = "com.franke.Whisky", jobs: BridgeJobStore) {
        WhiskyDataIdentity.configure("com.franke.Whisky")
        self.wineEnabled = wineEnabled
        self.jobs = jobs
        WhiskyPreferences.configureSharedDomain(preferencesDomain)
    }

    public var capabilities: [String] {
        ["system.files"] +
            (wineEnabled ? [
                "bottle.create",
                "wine.configuration",
                "processes.read"
            ] + RuntimeService.capabilities : [])
    }

    public var methods: [String] {
        ["system.reveal", "system.open", "system.resources"] + (wineEnabled ? [
            "bottle.create",
            "processes.list"
        ] + RuntimeService.methods : [])
    }

    private func bottle(_ url: URL) -> Bottle? {
        guard let data = try? ApplicationWorkspace.read(url.appendingPathComponent("Metadata.plist")),
              (try? PropertyListDecoder().decode(BottleSettings.self, from: data)) != nil
        else { return nil }
        if let existing = bottles[url], existing.0 == data {
            return existing.1
        }
        let bottle = Bottle(bottleUrl: url, isAvailable: true, cleanInvalidPins: false)
        bottles[url] = (data, bottle)
        return bottle
    }

    public func configurationChanged(
        _ field: ConfigurationField,
        value: ConfigurationValue,
        values: [String: ConfigurationValue],
        container: URL
    ) async throws {
        guard wineEnabled else { throw BridgeFailure("capability_unavailable", "Wine effects require --enable-wine") }
        guard let bottle = bottle(container) else { throw BridgeFailure(
            "invalid_container",
            "Wine settings are unreadable"
        ) }
        if field.id == "windowsVersion", case let .text(raw) = value, let version = WinVersion(rawValue: raw) {
            _ = try await Wine.changeWinVersion(bottle: bottle, win: version)
        } else {
            var values = values
            values[field.id] = value
            if values["virtualDesktopEnabled"] == .boolean(true) {
                let resolution = try virtualDesktopResolution(values)
                try await Wine.enableVirtualDesktop(bottle: bottle, resolution: resolution)
            } else if field.id == "virtualDesktopEnabled" {
                try await Wine.disableVirtualDesktop(bottle: bottle)
            }
        }
        bottles[container] = nil
    }

    public func call(
        _ method: String,
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) async throws -> JSONValue {
        guard methods.contains(method)
        else { throw BridgeFailure("method_unavailable", "Native method is unavailable") }
        switch method.prefix(while: { $0 != "." }) {
        case "system": return try systemCall(method, params: params, workspace: workspace)
        case "bottle": return try await createBottle(params: params, workspace: workspace)
        case "runtime": return try await runtimeService.call(method, params: params, workspace: workspace)
        case "processes": return try await listProcesses(params: params, workspace: workspace)
        default: throw BridgeFailure("method_unavailable", "Native method is unavailable")
        }
    }

    public func shutdown(applyExitPolicy: Bool) async {
        guard wineEnabled else { return }
        runtimeService.stopTracking()
        await GameActivityTracker.shared.stopPolling()
        SettingsPersistence.shared.flush()
        if applyExitPolicy {
            let globalKill = WhiskyPreferences.userDefaults.object(forKey: "killOnTerminate") as? Bool ?? true
            ApplicationShutdownService.apply(to: bottles.values.map(\.1), globalKill: globalKill)
        }
    }
}

// MARK: - Method dispatch

extension MacOSApplicationServices {
    private func createBottle(
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) async throws -> JSONValue {
        _ = try workspace.containers()
        let name = try params.text("name")
        let parent = try params.path("parent")
        guard let version = try WinVersion(rawValue: params.text("windowsVersion")) else {
            throw BridgeFailure("invalid_params", "Unknown Windows version")
        }
        return try jobs.start(name: "bottle.create") { progress in
            progress(.object(["stage": .string("initializing")]))
            do {
                let result = try await BottleCreationService.create(
                    name: name,
                    windowsVersion: version,
                    parentDirectory: parent,
                    destinationDirectory: parent
                        .appendingPathComponent(UUID().uuidString),
                    registry: BottleData(registryURL: workspace
                        .registry)
                )
                result.bottle.isAvailable = true
                result.bottle.inFlight = false
                return .object([
                    "path": .string(result.bottle.url.path),
                    "name": .string(result.bottle.settings.name)
                ])
            } catch let error as BottleCreationServiceError {
                let code = switch error {
                case .emptyName: "invalid_params"
                case .runtimeMissing: "runtime_missing"
                case .locationUnsuitable: "location_unsuitable"
                case .directoryCreationFailed: "destination_unavailable"
                case .metadataCreationFailed: "metadata_write_failed"
                case .registrySaveFailed: "registry_write_failed"
                }
                throw BridgeFailure(code, "Bottle creation failed: \(code)")
            }
        }
    }

    private func listProcesses(
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) async throws -> JSONValue {
        let container = try workspace.resolve(params)
        guard let bottle = bottle(container) else { throw BridgeFailure(
            "invalid_container",
            "Wine settings are unreadable"
        ) }
        let processes = try await Wine.listProcesses(for: bottle)
        return .array(processes.map { .object([
            "pid": .integer(Int64($0.winePID)),
            "name": .string($0.imageName),
            "memory": .string($0.memoryUsage),
            "kind": .string(String(describing: $0.kind))
        ]) })
    }
}
