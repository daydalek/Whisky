//
//  Service.swift
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
import WhiskyBridgeProtocol
import WhiskyCore

/// Host effects are explicit and injectable. GPUI receives errors and owns every dialog.
@MainActor
public protocol NativeApplicationServices: AnyObject {
    var methods: [String] { get }
    var capabilities: [String] { get }
    func call(_ method: String, params: [String: JSONValue], workspace: ApplicationWorkspace) async throws -> JSONValue
    func configurationChanged(
        _ field: ConfigurationField,
        value: ConfigurationValue,
        values: [String: ConfigurationValue],
        container: URL
    ) async throws
    func shutdown(applyExitPolicy: Bool) async
}

@MainActor
public final class ApplicationService {
    public let workspace: ApplicationWorkspace
    private let preferences: PreferencesService?
    private let lifecycleService: ContainerLifecycleService
    private let metadataService: LibraryMetadataService
    private var closed = false
    private var catalogues: [String: [EntryRecord]] = [:]
    private var catalogueOrder: [String] = []
    public let jobs: BridgeJobStore
    public let native: (any NativeApplicationServices)?
    public let runtime: RuntimeService?
    public let processes: ProcessService?
    public static let methods = [
        "bridge.describe", "bridge.shutdown", "jobs.get", "jobs.cancel", "library.scan", "library.page",
        "workspace.containers", "system.info",
        "library.entries",
        "folders.read",
        "folders.addRoot",
        "folders.addRoots",
        "folders.automaticMetadata",
        "folders.visibility",
        "folders.removeRoot",
        "folders.assign",
        "folders.exclude",
        "folders.executable",
        "folders.candidates",
        "entry.rating",
        "entry.hidden",
        "configuration.schema",
        "configuration.read",
        "configuration.set",
        "programs.list",
        "programs.pin",
        "programs.block",
        "programs.settings.read", "programs.settings.set",
        "programs.history.read", "programs.history.delete",
        "processes.list",
        "processes.kill",
        "processes.killAll",
        "environment.read",
        "environment.set"
    ] + LibraryMetadataService.methods
    public init(
        workspace: ApplicationWorkspace,
        native: (any NativeApplicationServices)? = nil,
        runtime: RuntimeService? = nil,
        processes: ProcessService? = nil,
        preferences: PreferencesService? = nil,
        jobs: BridgeJobStore? = nil
    ) {
        self.workspace = workspace
        self.native = native
        self.runtime = runtime
        self.processes = processes
        self.preferences = preferences
        let jobStore = jobs ?? BridgeJobStore()
        self.jobs = jobStore
        lifecycleService = ContainerLifecycleService(jobs: jobStore)
        metadataService = LibraryMetadataService(jobs: jobStore, networkAccess: { [weak preferences] in
            let values = try await preferences?.call("preferences.read", params: [:])
            if values?.object?["offlineMode"] == .bool(true) { throw URLError(.notConnectedToInternet) }
        })
    }

    public func respond(_ request: BridgeRequest) async -> BridgeResponse {
        do {
            guard !closed else { throw BridgeFailure("session_closed", "The bridge session has shut down") }
            guard request.version == BridgeRequest.version else { throw BridgeFailure(
                "version_mismatch",
                "Supported protocol version: 1"
            ) }
            guard !request.id.isEmpty, request.id.utf8.count <= 128 else { throw BridgeFailure(
                "invalid_request",
                "Invalid request ID"
            ) }
            let result = try await call(request.method, params: request.params)
            return BridgeResponse(id: request.id, result: result)
        } catch let error as BridgeFailure {
            return BridgeResponse(id: request.id, error: error)
        } catch { return BridgeResponse(
            id: request.id,
            error: BridgeFailure("operation_failed", error.localizedDescription)
        ) }
    }

    public func call(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
        let scope = method.prefix(while: { $0 != "." })
        switch scope {
        case "bridge": return try await bridgeCall(method, params: params)
        case "library", "workspace": return try await libraryCall(method, params: params)
        case "folders": return try await foldersCall(method, params: params)
        case "runtime": return try await runtimeCall(method, params: params)
        case "bottle":
            if native?.methods.contains(method) == true { return try await nativeCall(method, params: params) }
            if portableLifecycleMethods.contains(method) {
                return try await lifecycleService.call(method, params: params, workspace: workspace)
            }
            return try await nativeCall(method, params: params)
        case "metadata": return try await metadataService.call(method, params: params, workspace: workspace)
        default:
            if let result = try await scopedCall(scope, method: method, params: params) {
                return result
            }
            return try await nativeCall(method, params: params)
        }
    }

    public func shutdown(applyExitPolicy: Bool = false) async {
        guard !closed else { return }
        closed = true
        runtime?.stopTracking()
        await jobs.shutdown()
        await native?.shutdown(applyExitPolicy: applyExitPolicy)
    }
}

// MARK: - Method dispatch

extension ApplicationService {
    private func scopedCall(
        _ scope: Substring,
        method: String,
        params: [String: JSONValue]
    ) async throws -> JSONValue? {
        switch scope {
        case "preferences": return try await preferencesCall(method, params: params)
        case "jobs": return try await jobsCall(method, params: params)
        case "entry": return try await entryCall(method, params: params)
        case "configuration": return try await configurationCall(method, params: params)
        case "programs": return try await programCall(method, params: params)
        case "environment": return try await environmentCall(method, params: params)
        case "processes": return try await processesCall(method, params: params)
        case "system": return method == "system.info" ? ApplicationInfo.payload() : nil
        default: return nil
        }
    }

    private func runtimeCall(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
        if let runtime { return try await runtime.call(method, params: params, workspace: workspace) }
        return try await nativeCall(method, params: params)
    }

    private func processesCall(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
        if let processes { return try await processes.call(method, params: params, workspace: workspace) }
        return try await nativeCall(method, params: params)
    }

    private func bridgeCall(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
        switch method {
        case "bridge.describe":
            return describe()
        case "bridge.shutdown":
            let applyPolicy = params["applyExitPolicy"] == nil ? false : try params.flag("applyExitPolicy")
            await shutdown(applyExitPolicy: applyPolicy)
            return .object(["accepted": .bool(true)])
        default:
            return try await nativeCall(method, params: params)
        }
    }

    private var portableLifecycleMethods: [String] {
        #if os(Linux)
        ContainerLifecycleService.methods
        #else
        native == nil ? ContainerLifecycleService.methods : []
        #endif
    }

    private func describe() -> JSONValue {
        let extraMethods = (preferences == nil ? [] : PreferencesService.methods)
            + (runtime == nil ? [] : RuntimeService.methods)
            + (native?.methods ?? []) + portableLifecycleMethods
        let extraCapabilities = (runtime == nil ? [] : RuntimeService.capabilities)
            + (native?.capabilities ?? [])
            + (portableLifecycleMethods.isEmpty ? [] : ["bottle.lifecycle.file"])
        return .object([
            "protocolVersion": .integer(1),
            "platform": .string(Self.platform),
            "methods": .array(Array(Set(Self.methods + extraMethods)).sorted().map(JSONValue.string)),
            "capabilities": .array(Array(Set([
                "workspace.read",
                "library.read",
                "folders.edit",
                "configuration.file",
                "programs.edit",
                "programs.settings",
                "metadata.edit",
                "activity.rating",
                "visibility.edit"
            ] + extraCapabilities)).sorted().map(JSONValue.string)),
            "registry": .string(workspace.registry.path),
            "dateUnit": .string("unix_seconds"),
            "pathFormat": .string("absolute_native"),
            "maximumFrameBytes": .integer(Int64(BridgeFramer.maximumFrameBytes))
        ])
    }

    private func jobsCall(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
        switch method {
        case "jobs.get", "jobs.cancel": return try jobs.call(method, params: params)
        default: return try await nativeCall(method, params: params)
        }
    }

    private func preferencesCall(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
        switch method {
        case "preferences.read", "preferences.set", "preferences.schema":
            guard let preferences else { throw BridgeFailure("method_unavailable", "Preferences store is unavailable") }
            return try preferences.call(method, params: params)
        default:
            return try await nativeCall(method, params: params)
        }
    }

    private func libraryCall(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
        switch method {
        case "library.scan": return try scanLibrary(params)
        case "library.page": return try pageLibrary(params)
        case "library.entries": return try await listEntries(params)
        case "workspace.containers": return try .encoded(workspace.catalogue())
        default: return try await nativeCall(method, params: params)
        }
    }

    private func scanLibrary(_ params: [String: JSONValue]) throws -> JSONValue {
        _ = try workspace.resolve(params)
        return try jobs.start(name: "library.scan") { [self] progress in
            progress(.object(["stage": .string("scanning")]))
            let container = try workspace.resolve(params)
            let workspace = workspace
            let scan = Task.detached {
                let visibility = try LibraryVisibility.load(bottleURL: container)
                return try await workspace.entries(in: container).map {
                    try Task.checkCancellation()
                    return try EntryRecord($0, visibility: visibility)
                }
            }
            let records = try await withTaskCancellationHandler {
                try await scan.value
            } onCancel: { scan.cancel() }
            try Task.checkCancellation()
            guard records.count <= 50_000 else { throw BridgeFailure(
                "catalogue_too_large",
                "Catalogue exceeds 50000 entries"
            ) }
            let id = UUID().uuidString
            if catalogueOrder.count == 4 {
                catalogues[catalogueOrder.removeFirst()] = nil
            }
            catalogueOrder.append(id)
            catalogues[id] = records
            return .object(["snapshotID": .string(id), "total": .integer(Int64(records.count))])
        }
    }

    private func pageLibrary(_ params: [String: JSONValue]) throws -> JSONValue {
        let id = try params.text("snapshotID")
        guard let records = catalogues[id] else { throw BridgeFailure(
            "snapshot_expired",
            "Scan again to obtain a catalogue snapshot"
        ) }
        func integer(_ key: String, default value: Int, range: ClosedRange<Int>) throws -> Int {
            guard let raw = params[key] else { return value }
            guard case let .integer(number) = raw, let result = Int(exactly: number), range.contains(result)
            else { throw BridgeFailure("invalid_params", "Invalid pagination: \(key)") }
            return result
        }
        let offset = try integer("offset", default: 0, range: 0 ... records.count)
        let limit = try integer("limit", default: 50, range: 1 ... 100)
        let end = min(records.count, offset + limit)
        return try .object([
            "entries": .encoded(Array(records[offset ..< end])),
            "total": .integer(Int64(records.count)),
            "nextOffset": end < records.count ? .integer(Int64(end)) : .null
        ])
    }

    private func listEntries(_ params: [String: JSONValue]) async throws -> JSONValue {
        let container = try workspace.resolve(params)
        let visibility = try LibraryVisibility.load(bottleURL: container)
        return try await .encoded(workspace.entries(in: container)
            .map { try EntryRecord($0, visibility: visibility) })
    }

    private func entryCall(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
        switch method {
        case "entry.rating":
            let entry = try await workspace.entry(params)
            return try .encoded(workspace.setRating(try rating(params), entry: entry))
        case "entry.hidden":
            let entry = try await workspace.entry(params)
            _ = try workspace.setHidden(params.flag("hidden"), entry: entry)
            return try .object(["entryID": .string(entry.id), "hidden": .bool(params.flag("hidden"))])
        default:
            return try await nativeCall(method, params: params)
        }
    }

    private func rating(_ params: [String: JSONValue]) throws -> Int? {
        switch params["rating"] {
        case .null: return nil
        case let .integer(value):
            guard let rating = Int(exactly: value) else { throw BridgeFailure(
                "invalid_params",
                "Rating is out of range"
            ) }
            return rating
        default: throw BridgeFailure("invalid_params", "Expected integer or null: rating")
        }
    }

    private func programCall(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
        if ProgramHistoryService.methods.contains(method) {
            if native?.methods.contains(method) == true { return try await nativeCall(method, params: params) }
            return try ProgramHistoryService.call(method, params: params, workspace: workspace)
        }
        if ProgramSettingsService.methods.contains(method) {
            // The native adapter supplies the existing macOS bottle defaults.
            if native?.methods.contains(method) == true { return try await nativeCall(method, params: params) }
            return try await ProgramSettingsService.call(method, params: params, workspace: workspace)
        }
        switch method {
        case "programs.list": return try await listPrograms(params)
        case "programs.pin":
            let file = try configuration(params, containerOnly: true)
            try await file.setPinned(
                params.flag("pinned"),
                executable: params.path("executable"),
                name: params.text("name")
            )
            return try await call("programs.list", params: params)
        case "programs.block":
            let file = try configuration(params, containerOnly: true)
            try await file.setBlocked(params.flag("blocked"), executable: params.path("executable"))
            return try await call("programs.list", params: params)
        default:
            return try await nativeCall(method, params: params)
        }
    }

    private func listPrograms(_ params: [String: JSONValue]) async throws -> JSONValue {
        let container = try workspace.resolve(params)
        let programs = try await configuration(params, containerOnly: true).programs(in: container)
        return .array(programs.map { .object([
            "path": .string($0.url.path),
            "name": .string($0.name),
            "pinned": .bool($0.pinned),
            "blocked": .bool($0.blocked),
            "available": .bool($0.available)
        ]) })
    }

    private func environmentCall(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
        switch method {
        case "environment.read": return try await .object(configuration(params).strings(at: "environment")
                .mapValues(JSONValue.string))
        case "environment.set":
            let key = try params.text("key")
            let value: String?
            switch params["value"] {
            case .null: value = nil
            case let .string(text): value = text
            default: throw BridgeFailure("invalid_params", "Expected string or null: value")
            }
            try await configuration(params).setEnvironmentVariable(key, value: value)
            return try await call("environment.read", params: params)
        default:
            return try await nativeCall(method, params: params)
        }
    }

    func nativeCall(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
        guard let native, native.methods.contains(method) else { throw BridgeFailure(
            "method_unavailable",
            "Method is unavailable: \(method)"
        ) }
        return try await native.call(method, params: params, workspace: workspace)
    }

    func configuration(_ params: [String: JSONValue], containerOnly: Bool = false) throws -> ConfigurationFile {
        let container = try workspace.resolve(params)
        if !containerOnly, params["executable"] != nil {
            let executable = try params.path("executable")
            let locations = ProgramStorageLayout.locations(for: executable, containerURL: container)
            return ConfigurationFile(url: locations.identity, locking: HostFileLock(), fallbackURL: locations.legacy)
        }
        return ConfigurationFile(url: container.appendingPathComponent("Metadata.plist"), locking: HostFileLock())
    }

    private static var platform: String {
        #if os(macOS)
        "macos"
        #elseif os(Linux)
        "linux"
        #else
        "unsupported"
        #endif
    }
}
