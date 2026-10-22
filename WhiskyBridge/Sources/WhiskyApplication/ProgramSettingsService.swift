//
//  ProgramSettingsService.swift
//  WhiskyBridge
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

/// Shared storage for the complete GPUI program-settings sheet.
@MainActor
public enum ProgramSettingsService {
    public static let methods = ["programs.settings.read", "programs.settings.set"]

    public static func call(
        _ method: String, params: [String: JSONValue], workspace: ApplicationWorkspace,
        defaults: JSONValue? = nil
    ) async throws -> JSONValue {
        guard methods.contains(method) else { throw BridgeFailure(
            "method_unavailable",
            "Unknown program settings method"
        ) }
        let container = try workspace.resolve(params)
        let executable = try params.path("executable")
        guard executable.pathExtension.lowercased() == "exe" else {
            throw BridgeFailure("invalid_params", "Expected an .exe path: executable")
        }
        let defaultValues: JSONValue = if let defaults {
            defaults
        } else {
            try await containerDefaults(container)
        }
        let locations = ProgramStorageLayout.locations(for: executable, containerURL: container)
        let raw = try HostFileLock().withExclusiveLock(at: locations.identity.appendingPathExtension("lock")) {
            let source = FileManager.default.fileExists(atPath: locations.identity.path) ? locations
                .identity : locations.legacy
            var raw = try load(source)
            try validateStored(raw)
            if method == "programs.settings.set" {
                guard let patch = params["patch"]?.object else { throw BridgeFailure(
                    "invalid_params",
                    "Expected patch object"
                ) }
                try ProgramSettingsCodec.patch(patch, into: &raw)
                let data = try PropertyListSerialization.data(fromPropertyList: raw, format: .xml, options: 0)
                try data.write(to: locations.identity, options: .atomic)
            }
            return raw
        }
        var payload: [String: JSONValue] = try [
            "container": .string(container.path), "executable": .string(executable.path),
            "programName": .string(executable.lastPathComponent),
            "locale": .string(ContainerConfiguration.locales.first { $0.0 == raw["locale"] as? String }?.0 ?? ""),
            "arguments": .string(raw["arguments"] as? String ?? ""),
            "environment": .object((raw["environment"] as? [String: String] ?? [:]).mapValues(JSONValue.string)),
            "defaults": defaultValues, "available": .bool(FileManager.default.fileExists(atPath: executable.path)),
            "overrides": (raw["overrides"] as? [String: Any]).map(ProgramSettingsCodec.overrides) ?? .null
        ]
        if let storedURL = raw["lastLogFileURL"] {
            let data = try PropertyListSerialization.data(fromPropertyList: storedURL, format: .binary, options: 0)
            let url = try PropertyListDecoder().decode(URL.self, from: data)
            payload["lastLogFile"] = .string(url.path)
        }
        if let date = raw["lastDiagnosisDate"] as? Date {
            payload["lastDiagnosisDate"] = .integer(Int64(date.timeIntervalSince1970))
        }
        return .object(payload)
    }

    static func load(_ source: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: source.path) else { return [:] }
        guard try (source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 16 * 1_024 * 1_024,
              let raw = try PropertyListSerialization
                  .propertyList(from: Data(contentsOf: source), format: nil) as? [String: Any]
        else { throw BridgeFailure("invalid_settings", "Program storage is unreadable or too large") }
        return raw
    }

    private static func validateStored(_ raw: [String: Any]) throws {
        for key in ["arguments", "locale"] where raw[key] != nil {
            guard raw[key] is String else { throw BridgeFailure("invalid_settings", "Invalid stored \(key)") }
        }
        if let environment = raw["environment"], !(environment is [String: String]) {
            throw BridgeFailure("invalid_settings", "Invalid stored environment")
        }
        if let overrides = raw["overrides"] {
            guard let object = overrides as? [String: Any] else { throw BridgeFailure(
                "invalid_settings",
                "Invalid stored overrides"
            ) }
            _ = try ProgramSettingsCodec.overrides(object)
        }
    }

    private static func containerDefaults(_ container: URL) async throws -> JSONValue {
        let fields = ContainerConfiguration.fields
        let file = ConfigurationFile(url: container.appendingPathComponent("Metadata.plist"), locking: HostFileLock())
        let values = try await file.values(for: fields)
        var payload: [String: JSONValue] = [:]
        for key in ProgramSettingsCodec.keys {
            guard let value = values[key] else { continue }
            switch value {
            case let .boolean(flag): payload[key] = .bool(flag)
            case let .text(text): payload[key] = .string(text)
            case let .integer(number): payload[key] = .integer(Int64(number))
            }
        }
        let metadata = try load(container.appendingPathComponent("Metadata.plist"))
        payload["dllOverrides"] = try ProgramSettingsCodec.wire(metadata["customDLLOverrides"] ?? [])
        return .object(payload)
    }
}
