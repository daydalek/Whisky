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
    let jobs: BridgeJobStore
    private lazy var driver = WineLibraryRuntimeDriver(
        bottleResolver: { [weak self] in self?.bottle($0) },
        driverFactory: { MonitoredSteamClientDriver(bottle: $0) }
    )
    /// Shared with `ApplicationService` so `runtime.*` requests take the same
    /// controller path as the SwiftUI app instead of a second instance.
    public lazy var runtimeService = RuntimeService(
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
        ["system.files", "programs.settings", "programs.shortcut"] +
            (wineEnabled ? [
                "bottle.create",
                "wine.configuration",
                "processes.read",
                "winetricks.verbs",
                "winetricks.install"
            ] + RuntimeService.capabilities : [])
    }

    public var methods: [String] {
        [
            "system.reveal", "system.open", "system.resources",
            "programs.settings.read", "programs.settings.set",
            "programs.history.read", "programs.history.delete",
            "programs.shortcut.create"
        ] + (wineEnabled ? [
            "bottle.create",
            "winetricks.catalog",
            "winetricks.installed",
            "winetricks.install"
        ] + RuntimeService.methods : [])
    }

    /// Shared with `ApplicationService` so `processes.*` reuses the same
    /// tasklist snapshot and kill calls the SwiftUI Processes page drives.
    public lazy var processService = ProcessService(
        host: WineProcessHost(bottle: { [weak self] in self?.bottle($0) })
    )

    func bottle(_ url: URL) -> Bottle? {
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
        case "programs": return try await programsCall(method, params: params, workspace: workspace)
        case "winetricks": return try await winetricksCall(method, params: params, workspace: workspace)
        case "runtime": return try await runtimeService.call(method, params: params, workspace: workspace)
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
}

/// `ProcessSnapshotProviding` over the same WhiskyKit calls the SwiftUI
/// `ProcessesViewModel` uses: `Wine.listProcesses` (the Unicode Toolhelp
/// snapshot) for enumeration and `taskkill.exe` for termination. The `bottle`
/// resolver is `MacOSApplicationServices.bottle`, kept behind a closure so the
/// adapter never outlives its service.
@MainActor
private final class WineProcessHost: ProcessSnapshotProviding {
    private let bottle: @MainActor (URL) -> Bottle?

    init(bottle: @escaping @MainActor (URL) -> Bottle?) {
        self.bottle = bottle
    }

    func listProcesses(in container: URL) async throws -> [ProcessRecord] {
        guard let bottle = bottle(container) else { throw BridgeFailure(
            "invalid_container",
            "Wine settings are unreadable"
        ) }
        return try await Wine.listProcesses(for: bottle).map { process in
            ProcessRecord(
                pid: process.winePID,
                name: process.imageName,
                memory: process.memoryUsage,
                kind: process.kind.rawValue,
                source: process.source.rawValue,
                startedAt: process.launchTime,
                macosPID: process.macosPID
            )
        }
    }

    func terminateProcess(in container: URL, pid: Int32, force: Bool) async throws {
        guard let bottle = bottle(container) else { throw BridgeFailure(
            "invalid_container",
            "Wine settings are unreadable"
        ) }
        if force {
            await Wine.forceKillProcess(winePID: pid, bottle: bottle)
        } else {
            await Wine.gracefulKillProcess(winePID: pid, bottle: bottle)
        }
    }

    func terminateAllProcesses(in container: URL) async throws {
        guard let bottle = bottle(container) else { throw BridgeFailure(
            "invalid_container",
            "Wine settings are unreadable"
        ) }
        Wine.killBottle(bottle: bottle)
        ProcessRegistry.shared.clearRegistry(for: bottle.url)
    }
}
