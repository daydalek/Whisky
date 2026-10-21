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
    private var closed = false
    private var catalogues: [String: [EntryRecord]] = [:]
    private var catalogueOrder: [String] = []
    public let jobs: BridgeJobStore
    public let native: (any NativeApplicationServices)?
    public static let methods = [
        "bridge.describe", "bridge.shutdown", "jobs.get", "jobs.cancel", "library.scan", "library.page",
        "workspace.containers",
        "library.entries",
        "entry.rating",
        "entry.hidden",
        "configuration.schema",
        "configuration.read",
        "configuration.set",
        "programs.list",
        "programs.pin",
        "programs.block",
        "environment.read",
        "environment.set"
    ]
    public init(
        workspace: ApplicationWorkspace,
        native: (any NativeApplicationServices)? = nil,
        preferences: PreferencesService? = nil,
        jobs: BridgeJobStore? = nil
    ) {
        self.workspace = workspace
        self.native = native
        self.preferences = preferences
        self.jobs = jobs ?? BridgeJobStore()
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
        } catch let error as BridgeFailure { return BridgeResponse(id: request.id, error: error) }
        catch { return BridgeResponse(
            id: request.id,
            error: BridgeFailure("operation_failed", error.localizedDescription)
        ) }
    }

    public func call(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
        switch method {
        case "bridge.describe":
            return .object([
                "protocolVersion": .integer(1),
                "platform": .string(Self.platform),
                "methods": .array((Self
                        .methods + (preferences == nil ? [] : PreferencesService.methods) + (native?.methods ?? []))
                    .sorted()
                    .map(JSONValue.string)),
                "capabilities": .array(([
                    "workspace.read",
                    "library.read",
                    "configuration.file",
                    "programs.edit",
                    "activity.rating",
                    "visibility.edit"
                ] + (native?.capabilities ?? [])).map(JSONValue.string)),
                "registry": .string(workspace.registry.path),
                "dateUnit": .string("unix_seconds"),
                "pathFormat": .string("absolute_native"),
                "maximumFrameBytes": .integer(Int64(BridgeFramer.maximumFrameBytes))
            ])
        case "preferences.read", "preferences.set", "preferences.schema":
            guard let preferences else { throw BridgeFailure("method_unavailable", "Preferences store is unavailable") }
            return try preferences.call(method, params: params)
        case "bridge.shutdown":
            let applyPolicy = params["applyExitPolicy"] == nil ? false : try params.flag("applyExitPolicy")
            await shutdown(applyExitPolicy: applyPolicy)
            return .object(["accepted": .bool(true)])
        case "jobs.get", "jobs.cancel": return try jobs.call(method, params: params)
        case "library.scan":
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
        case "library.page":
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
        case "workspace.containers": return try .encoded(workspace.catalogue())
        case "library.entries":
            let container = try workspace.resolve(params)
            let visibility = try LibraryVisibility.load(bottleURL: container)
            return try await .encoded(workspace.entries(in: container)
                .map { try EntryRecord($0, visibility: visibility) })
        case "entry.rating":
            let entry = try await workspace.entry(params)
            let rating: Int?
            switch params["rating"] {
            case .null: rating = nil
            case let .integer(value):
                guard let value = Int(exactly: value) else { throw BridgeFailure(
                    "invalid_params",
                    "Rating is out of range"
                ) }
                rating = value
            default: throw BridgeFailure("invalid_params", "Expected integer or null: rating")
            }
            return try .encoded(workspace.setRating(rating, entry: entry))
        case "entry.hidden":
            let entry = try await workspace.entry(params)
            _ = try workspace.setHidden(params.flag("hidden"), entry: entry)
            return try .object(["entryID": .string(entry.id), "hidden": .bool(params.flag("hidden"))])
        case "configuration.schema": return .array(Self.fields(params).map(Self.describe))
        case "configuration.read":
            let file = try configuration(params)
            return try await .object(file.values(for: Self.fields(params)).mapValues(Self.encode))
        case "configuration.set":
            let container = try workspace.resolve(params)
            let fieldID = try params.text("field")
            let fields = Self.fields(params)
            guard let field = fields.first(where: { $0.id == fieldID }), let input = params["value"] else {
                throw BridgeFailure("invalid_params", "Unknown field or missing value")
            }
            let value = try Self.decode(input)
            try field.validate(value)
            let file = try configuration(params)
            let current = try await file.values(for: fields)
            if current[field.id] != value {
                let hostFields: Set = [
                    "windowsVersion",
                    "virtualDesktopEnabled",
                    "resolutionPreset",
                    "customResolutionWidth",
                    "customResolutionHeight"
                ]
                if params["executable"] == nil, hostFields.contains(field.id) {
                    guard let native else { throw BridgeFailure(
                        "capability_unavailable",
                        "This setting requires the Wine host adapter"
                    ) }
                    try await native.configurationChanged(field, value: value, values: current, container: container)
                }
                try await file.update(field, to: value)
            }
            return try await .object(file.values(for: fields).mapValues(Self.encode))
        case "programs.list":
            let container = try workspace.resolve(params)
            let programs = try await configuration(params, containerOnly: true).programs(in: container)
            return .array(programs.map { .object([
                "path": .string($0.url.path),
                "name": .string($0.name),
                "pinned": .bool($0.pinned),
                "blocked": .bool($0.blocked),
                "available": .bool($0.available)
            ]) })
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
            guard let native, native.methods.contains(method) else { throw BridgeFailure(
                "method_unavailable",
                "Method is unavailable: \(method)"
            ) }
            return try await native.call(method, params: params, workspace: workspace)
        }
    }

    public func shutdown(applyExitPolicy: Bool = false) async {
        guard !closed else { return }
        closed = true
        await jobs.shutdown()
        await native?.shutdown(applyExitPolicy: applyExitPolicy)
    }

    private func configuration(_ params: [String: JSONValue], containerOnly: Bool = false) throws -> ConfigurationFile {
        let container = try workspace.resolve(params)
        if !containerOnly, params["executable"] != nil {
            let executable = try params.path("executable")
            let locations = ProgramStorageLayout.locations(for: executable, containerURL: container)
            return ConfigurationFile(url: locations.identity, locking: HostFileLock(), fallbackURL: locations.legacy)
        }
        return ConfigurationFile(url: container.appendingPathComponent("Metadata.plist"), locking: HostFileLock())
    }

    private static var containerFields: [ConfigurationField] {
        ContainerConfiguration.fields
    }

    private static func fields(_ params: [String: JSONValue]) -> [ConfigurationField] {
        params["executable"] == nil ? containerFields : [
            ContainerConfiguration.choice("programLocale", "语言区域", "locale", "", ContainerConfiguration.locales),
            .init("arguments", "运行参数", path: "arguments", input: .text, defaultValue: .text(""))
        ]
    }

    private nonisolated static func encode(_ value: ConfigurationValue) -> JSONValue {
        switch value { case let .boolean(v): .bool(v)
        case let .integer(v): .integer(Int64(v))
        case let .text(v): .string(v) }
    }

    private nonisolated static func decode(_ value: JSONValue) throws -> ConfigurationValue {
        switch value {
        case let .bool(v): return .boolean(v)
        case let .integer(v): guard let v = Int(exactly: v) else { break }
            return .integer(v)
        case let .string(v): return .text(v)
        default: break
        }
        throw BridgeFailure("invalid_params", "Expected a boolean, integer or string setting")
    }

    private nonisolated static func describe(_ field: ConfigurationField) -> JSONValue {
        var result: [String: JSONValue] = [
            "id": .string(field.id),
            "title": .string(field.title),
            "default": encode(field.defaultValue)
        ]
        let hostFields: Set = [
            "windowsVersion",
            "virtualDesktopEnabled",
            "resolutionPreset",
            "customResolutionWidth",
            "customResolutionHeight"
        ]
        result["requires"] = .array(hostFields.contains(field.id) ? [.string("wine.configuration")] : [])
        switch field.input {
        case .toggle: result["input"] = .string("toggle")
        case .text: result["input"] = .string("text")
        case let .number(range):
            result["input"] = .string("number")
            result["min"] = .integer(Int64(range.lowerBound))
            result["max"] = .integer(Int64(range.upperBound))
        case let .choice(options):
            result["input"] = .string("choice")
            result["options"] = .array(options.map { .object(["id": .string($0.id), "title": .string($0.title)]) })
        }
        return .object(result)
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
