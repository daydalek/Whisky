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

import AppKit
import Foundation
import WhiskyApplication
import WhiskyBridgeProtocol
import WhiskyCore
import WhiskyKit

/// The helper publishes values; GPUI owns prompts and visual state.
@MainActor
public final class MacOSApplicationServices: NativeApplicationServices {
    private var bottles: [URL: (Data, Bottle)] = [:]
    private var configured: [String: LibraryEntry] = [:]
    private var sequence: UInt64 = 0
    private var eventBuffer: [(UInt64, JSONValue)] = []
    private var observer: Task<Void, Never>?
    private let interactions = LaunchInteractionBroker()
    private let wineEnabled: Bool
    private let jobs: BridgeJobStore
    private lazy var driver = WineLibraryRuntimeDriver(
        bottleResolver: { [weak self] in self?.bottle($0) },
        driverFactory: { MonitoredSteamClientDriver(bottle: $0) }
    )
    private lazy var runtime = LibraryRuntimeController(driver: driver)
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
                "runtime.launch",
                "runtime.events",
                "processes.read"
            ] : [])
    }

    public var methods: [String] {
        ["system.reveal", "system.open", "system.resources"] + (wineEnabled ? [
            "bottle.create", "runtime.configure", "runtime.snapshot", "runtime.events", "runtime.launch",
            "runtime.cancel",
            "runtime.stop",
            "processes.list"
        ] : [])
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
                let resolution: String
                switch values["resolutionPreset"] {
                case .text("custom"):
                    guard case let .integer(width) = values["customResolutionWidth"],
                          case let .integer(height) = values["customResolutionHeight"]
                    else {
                        throw BridgeFailure("invalid_params", "Custom resolution requires width and height")
                    }
                    resolution = "\(width)x\(height)"
                case .text("matchDisplay"):
                    guard let screen = NSScreen.main else { throw BridgeFailure(
                        "display_unavailable",
                        "Display dimensions are unavailable"
                    ) }
                    resolution = "\(Int(screen.frame.width * screen.backingScaleFactor))x\(Int(screen.frame.height * screen.backingScaleFactor))"
                case let .text(preset): resolution = String(preset.dropFirst())
                default: throw BridgeFailure("invalid_params", "Resolution preset is unavailable")
                }
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
        switch method {
        case "system.resources":
            return .object([
                "kitBundle": .string(WhiskyResources.kitBundleURL.path),
                "tools": .object(Dictionary(uniqueKeysWithValues: ["cabextract", "winetricks", "verbs.txt"].map {
                    ($0, WhiskyResources.tool($0).map { .string($0.path) } ?? .null)
                }))
            ])
        case "system.reveal", "system.open":
            let container = try workspace.resolve(params)
            let path = params["path"] == nil ? container : try params.path("path")
            guard FileManager.default.fileExists(atPath: path.path) else { throw BridgeFailure(
                "file_missing",
                "Selected file is unavailable"
            ) }
            if method == "system.reveal" {
                NSWorkspace.shared.activateFileViewerSelecting([path])
            } else if !NSWorkspace.shared.open(path) {
                throw BridgeFailure(
                    "host_failed",
                    "macOS could not open the selected file"
                )
            }
            return .object(["accepted": .bool(true)])
        case "bottle.create":
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
        case "runtime.configure":
            let container = try workspace.resolve(params)
            let entries = try await workspace.entries(in: container)
            configured = configured.filter { $0.value.bottleURL != container }
            for entry in entries {
                configured[entry.id] = entry
            }
            try runtime.retainContainers(Set(workspace.containers()))
            if observer == nil {
                let stream = runtime.events()
                observer = Task { [weak self] in
                    for await event in stream {
                        guard let self else { break }
                        self.sequence &+= 1
                        self.eventBuffer.append((self.sequence, self.event(event)))
                        if self.eventBuffer.count > 128 {
                            self.eventBuffer.removeFirst()
                        }
                    }
                }
            }
            await runtime.configure(entries: entries, containerURL: container)
            return snapshot()
        case "runtime.snapshot": return snapshot()
        case "runtime.events":
            let after = try params.text("after")
            guard let cursor = UInt64(after) else { throw BridgeFailure("invalid_params", "Invalid event sequence") }
            return .object([
                "sequence": .string(String(sequence)),
                "resyncRequired": .bool(cursor > sequence ||
                    (eventBuffer.first.map { cursor < $0.0 - 1 } ?? false)),
                "events": .array(eventBuffer.filter { $0.0 > cursor }.map { .object([
                    "sequence": .string(String($0.0)),
                    "event": $0.1
                ]) }),
                "snapshot": snapshot()
            ])
        case "runtime.launch", "runtime.cancel", "runtime.stop":
            let entry = try await workspace.entry(params)
            guard configured[entry.id] != nil else { throw BridgeFailure(
                "not_configured",
                "Configure this library before launching"
            ) }
            let capabilities = runtime.capabilities(for: entry)
            if method == "runtime.launch" {
                guard capabilities.contains(.launch) else { throw BridgeFailure(
                    "capability_unavailable",
                    "Launch is unavailable for this entry"
                ) }
                let mode = params["mode"]?.string ?? "standard"
                guard mode == "standard" || mode == "terminal" else { throw BridgeFailure(
                    "invalid_params",
                    "Unknown launch mode"
                ) }
                if mode == "terminal", !capabilities.contains(.terminal) {
                    throw BridgeFailure(
                        "capability_unavailable",
                        "Terminal launch is unavailable"
                    )
                }
                if let prompt = try clipboardPreflight(params, entry: entry) {
                    return prompt
                }
                // Re-read program settings after edits performed through the portable service.
                bottles[entry.bottleURL] = nil
                let executable = params["executable"] == nil ? nil : try params.path("executable")
                runtime.launch(.init(
                    entry: entry,
                    executableURL: executable,
                    mode: mode == "terminal" ? .terminal : .standard
                ))
            } else if method == "runtime.cancel" {
                guard capabilities.contains(.cancelLaunch) else { throw BridgeFailure(
                    "capability_unavailable",
                    "Cancellation is unavailable"
                ) }
                runtime.cancelLaunch(for: entry)
            } else {
                guard capabilities.contains(.stop) else { throw BridgeFailure(
                    "capability_unavailable",
                    "Stop is unavailable for this entry"
                ) }
                await runtime.stop(entry)
            }
            return .object(["accepted": .bool(true), "entryID": .string(entry.id)])
        case "processes.list":
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
        default: throw BridgeFailure("method_unavailable", "Native method is unavailable")
        }
    }

    public func shutdown(applyExitPolicy: Bool) async {
        guard wineEnabled else { return }
        runtime.stopTracking()
        await GameActivityTracker.shared.stopPolling()
        SettingsPersistence.shared.flush()
        if applyExitPolicy {
            let globalKill = WhiskyPreferences.userDefaults.object(forKey: "killOnTerminate") as? Bool ?? true
            ApplicationShutdownService.apply(to: bottles.values.map(\.1), globalKill: globalKill)
        }
    }

    private func clipboardPreflight(_ params: [String: JSONValue], entry: LibraryEntry) throws -> JSONValue? {
        let clipboard = ClipboardManager.shared
        if params["interactionToken"] != nil {
            try interactions.resolve(
                token: params.text("interactionToken"),
                entryID: entry.id,
                decision: params.text("clipboardDecision"),
                clipboard: clipboard
            )
            return nil
        }
        guard let bottle = bottle(entry.bottleURL) else { throw BridgeFailure(
            "invalid_container",
            "Wine settings are unreadable"
        ) }
        return interactions.assess(
            entryID: entry.id,
            clipboard: clipboard,
            launcher: bottle.settings.detectedLauncher,
            policy: bottle.settings.clipboardPolicy,
            threshold: bottle.settings.clipboardThreshold
        )
    }

    private func snapshot(_ supplied: LibraryRuntimeState? = nil) -> JSONValue {
        let state = supplied ?? runtime.state
        return .object([
            "sequence": .string(String(sequence)),
            "entries": .array(configured.values.sorted { $0.id < $1.id }.map { entry in
                .object([
                    "id": .string(entry.id),
                    "state": .string(state.launch.state(for: entry).rawValue),
                    "capabilities": .integer(Int64(runtime.capabilities(for: entry).rawValue))
                ])
            }),
            "queryFailures": .object(Dictionary(uniqueKeysWithValues: state.queryFailures.map { (
                $0.key.path,
                .string($0.value)
            ) }))
        ])
    }

    private func event(_ event: LibraryRuntimeEvent) -> JSONValue {
        switch event {
        case let .state(state): return .object(["kind": .string("state"), "value": snapshot(state)])
        case let .launchResult(entryID, result):
            let kind = switch result { case .launchedSuccessfully: "launched"
            case .launchedInTerminal: "terminal"
            case .launchFailed: "failed" }
            return .object([
                "kind": .string("launchResult"),
                "entryID": .string(entryID),
                "status": .string(kind),
                "program": .string(result.programName),
                "error": result.errorDescription.map(JSONValue.string) ?? .null
            ])
        case let .failure(error): return .object([
                "kind": .string("failure"),
                "message": .string(String(describing: error))
            ])
        }
    }
}
