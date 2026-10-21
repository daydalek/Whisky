//
//  RuntimeService.swift
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

/// Portable bridge adapter over `LibraryRuntimeController` and `LaunchInteractionBroker`.
@MainActor
public final class RuntimeService {
    public typealias ClipboardPolicySnapshot = (
        launcher: LauncherType?,
        policy: ClipboardPolicy,
        threshold: Int
    )

    public static let capabilities = ["runtime.launch", "runtime.events"]
    public static let methods = [
        "runtime.configure",
        "runtime.snapshot",
        "runtime.events",
        "runtime.launch",
        "runtime.cancel",
        "runtime.stop"
    ]

    private let runtime: LibraryRuntimeController
    private let interactions = LaunchInteractionBroker()
    private let clipboard: (@MainActor () -> (any ClipboardAccess)?)?
    private let policyLoader: (@MainActor (URL) throws -> ClipboardPolicySnapshot)?
    private let beforeLaunch: (@MainActor (LibraryEntry) -> Void)?
    private var configured: [String: LibraryEntry] = [:]
    private var sequence: UInt64 = 0
    private var eventBuffer: [(UInt64, JSONValue)] = []
    private var observer: Task<Void, Never>?

    public init(
        driver: any LibraryRuntimeDriver,
        launchTimeout: Duration = .seconds(120),
        clipboard: (@MainActor () -> (any ClipboardAccess)?)? = nil,
        policyLoader: (@MainActor (URL) throws -> ClipboardPolicySnapshot)? = nil,
        beforeLaunch: (@MainActor (LibraryEntry) -> Void)? = nil
    ) {
        runtime = LibraryRuntimeController(driver: driver, launchTimeout: launchTimeout)
        self.clipboard = clipboard
        self.policyLoader = policyLoader
        self.beforeLaunch = beforeLaunch
    }

    public func stopTracking() {
        observer?.cancel()
        observer = nil
        runtime.stopTracking()
    }

    public func call(
        _ method: String,
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) async throws -> JSONValue {
        switch method {
        case "runtime.configure": return try await configureRuntime(params: params, workspace: workspace)
        case "runtime.snapshot": return snapshot()
        case "runtime.events": return try runtimeEvents(params)
        case "runtime.launch", "runtime.cancel", "runtime.stop":
            return try await controlRuntime(method, params: params, workspace: workspace)
        default:
            throw BridgeFailure("method_unavailable", "Runtime method is unavailable: \(method)")
        }
    }

    private func configureRuntime(
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) async throws -> JSONValue {
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
                    self.eventBuffer.append((self.sequence, self.encodeEvent(event)))
                    if self.eventBuffer.count > 128 {
                        self.eventBuffer.removeFirst()
                    }
                }
            }
        }
        await runtime.configure(entries: entries, containerURL: container)
        return snapshot()
    }

    private func runtimeEvents(_ params: [String: JSONValue]) throws -> JSONValue {
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
    }

    private func controlRuntime(
        _ method: String,
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) async throws -> JSONValue {
        let entry = try await workspace.entry(params)
        guard configured[entry.id] != nil else { throw BridgeFailure(
            "not_configured",
            "Configure this library before launching"
        ) }
        let capabilities = runtime.capabilities(for: entry)
        switch method {
        case "runtime.launch":
            return try await launch(entry: entry, capabilities: capabilities, params: params)
        case "runtime.cancel":
            guard capabilities.contains(.cancelLaunch) else { throw BridgeFailure(
                "capability_unavailable",
                "Cancellation is unavailable"
            ) }
            runtime.cancelLaunch(for: entry)
        default:
            guard capabilities.contains(.stop) else { throw BridgeFailure(
                "capability_unavailable",
                "Stop is unavailable for this entry"
            ) }
            await runtime.stop(entry)
        }
        return .object(["accepted": .bool(true), "entryID": .string(entry.id)])
    }

    private func launch(
        entry: LibraryEntry,
        capabilities: LibraryRuntimeCapabilities,
        params: [String: JSONValue]
    ) async throws -> JSONValue {
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
            throw BridgeFailure("capability_unavailable", "Terminal launch is unavailable")
        }
        if let prompt = try await clipboardPreflight(params, entry: entry) {
            return prompt
        }
        beforeLaunch?(entry)
        let executable = params["executable"] == nil ? nil : try params.path("executable")
        runtime.launch(.init(
            entry: entry,
            executableURL: executable,
            mode: mode == "terminal" ? .terminal : .standard
        ))
        return .object(["accepted": .bool(true), "entryID": .string(entry.id)])
    }

    private func clipboardPreflight(
        _ params: [String: JSONValue],
        entry: LibraryEntry
    ) async throws -> JSONValue? {
        guard let clipboard = clipboard?() else { return nil }
        if params["interactionToken"] != nil {
            try interactions.resolve(
                token: params.text("interactionToken"),
                entryID: entry.id,
                decision: params.text("clipboardDecision"),
                clipboard: clipboard
            )
            return nil
        }
        let policy: ClipboardPolicySnapshot = if let policyLoader {
            try policyLoader(entry.bottleURL)
        } else {
            try await Self.loadClipboardPolicy(from: entry.bottleURL)
        }
        return interactions.assess(
            entryID: entry.id,
            clipboard: clipboard,
            launcher: policy.launcher,
            policy: policy.policy,
            threshold: policy.threshold
        )
    }

    private static func loadClipboardPolicy(from containerURL: URL) async throws -> ClipboardPolicySnapshot {
        let metadataURL = containerURL.appendingPathComponent("Metadata.plist")
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw BridgeFailure("invalid_container", "Wine settings are unreadable")
        }
        let file = ConfigurationFile(url: metadataURL, locking: HostFileLock())
        do {
            return try await file.clipboardPreflightConfiguration()
        } catch {
            throw BridgeFailure("invalid_container", "Wine settings are unreadable")
        }
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

    private func encodeEvent(_ event: LibraryRuntimeEvent) -> JSONValue {
        switch event {
        case let .state(state):
            return .object(["kind": .string("state"), "value": snapshot(state)])
        case let .launchResult(entryID, result):
            let kind = switch result {
            case .launchedSuccessfully: "launched"
            case .launchedInTerminal: "terminal"
            case .launchFailed: "failed"
            }
            return .object([
                "kind": .string("launchResult"),
                "entryID": .string(entryID),
                "status": .string(kind),
                "program": .string(result.programName),
                "error": result.errorDescription.map(JSONValue.string) ?? .null
            ])
        case let .failure(error):
            return .object([
                "kind": .string("failure"),
                "message": .string(String(describing: error))
            ])
        }
    }
}
