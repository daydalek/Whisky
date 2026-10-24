//
//  ProgramSettingsCodec.swift
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

/// Wire validation and native plist representation of per-program overrides.
enum ProgramSettingsCodec {
    static let booleans: Set<String> = [
        "dxvk", "dxvkAsync", "metal4Enabled", "shaderCacheEnabled", "controllerCompatibilityMode",
        "disableHIDAPI", "allowBackgroundEvents", "disableControllerMapping", "useButtonLabels",
        "virtualDesktopEnabled"
    ]
    static let choices: [String: Set<String>] = Dictionary(uniqueKeysWithValues:
        ContainerConfiguration.fields.compactMap { field in
            guard ["graphicsBackend", "dxvkHud", "enhancedSync", "resolutionPreset"].contains(field.id),
                  case let .choice(options) = field.input
            else { return nil }
            return (field.id, Set(options.map(\.id)))
        }
    )
    static let tagged: Set<String> = ["dxvkHud", "enhancedSync"]
    static var keys: Set<String> {
        booleans.union(choices.keys).union([
            "customResolutionWidth",
            "customResolutionHeight",
            "dllOverrides",
            "taggedVerbs"
        ])
    }

    static func validate(_ value: JSONValue, key: String) throws {
        let valid: Bool = if booleans.contains(key) {
            value.bool != nil
        } else if let options = choices[key] {
            value.string.map { options.contains($0) } ?? false
        } else if key == "customResolutionWidth" || key == "customResolutionHeight" {
            value.integer.map { (200 ... 16_384).contains($0) } ?? false
        } else if key == "taggedVerbs", case let .array(items) = value {
            items.allSatisfy { $0.string.map { !$0.isEmpty } ?? false }
        } else if key == "dllOverrides", case let .array(items) = value {
            items.allSatisfy { item in
                guard let object = item.object, let name = object["dllName"]?.string,
                      let mode = object["mode"]?.string
                else { return false }
                return !name.isEmpty && name.utf8.count <= 64
                    && !name.contains { $0.isWhitespace || $0 == "=" || $0 == "," || $0 == "\0" }
                    && ["n,b", "b,n", "n", "b", ""].contains(mode)
            }
        } else {
            false
        }
        guard valid else { throw BridgeFailure("invalid_params", "Invalid program override: \(key)") }
    }

    static func environment(_ value: JSONValue) throws -> [String: String] {
        guard let object = value.object else { throw BridgeFailure("invalid_params", "Expected environment object") }
        return try object.mapValues { item in
            guard let text = item.string, !text.contains("\0"), text.utf8.count <= 16_384 else {
                throw BridgeFailure("invalid_params", "Invalid environment value")
            }
            return text
        }.reduce(into: [:]) { result, pair in
            let (key, text) = pair
            guard !key.isEmpty, !key.contains("="), !key.contains("\0"), key.utf8.count <= 256 else {
                throw BridgeFailure("invalid_params", "Invalid environment key")
            }
            result[key] = text
        }
    }

    static func foundation(_ value: JSONValue) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])
    }

    static func wire(_ value: Any) throws -> JSONValue {
        try JSONDecoder().decode(
            JSONValue.self,
            from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        )
    }

    static func overrides(_ raw: [String: Any]) throws -> JSONValue {
        var payload: [String: JSONValue] = [:]
        for key in keys {
            guard var value = raw[key] else { continue }
            if tagged.contains(key) {
                guard let tags = value as? [String: Any], tags.count == 1, let tag = tags.keys.first else {
                    throw BridgeFailure("invalid_settings", "Invalid stored override: \(key)")
                }
                value = tag
            }
            let encoded = try wire(value)
            if ["graphicsBackend", "resolutionPreset"].contains(key),
               let text = encoded.string, choices[key]?.contains(text) == false {
                continue
            }
            try validate(encoded, key: key)
            payload[key] = encoded
        }
        return .object(payload)
    }

    static func patch(_ patch: [String: JSONValue], into raw: inout [String: Any]) throws {
        guard patch.keys.allSatisfy({ ["locale", "arguments", "environment", "overrides"].contains($0) }) else {
            throw BridgeFailure("invalid_params", "Unknown program setting")
        }
        if let value = patch["locale"] {
            guard let locale = value.string, ContainerConfiguration.locales.contains(where: { $0.0 == locale }) else {
                throw BridgeFailure("invalid_params", "Unknown locale")
            }
            var environment = raw["environment"] as? [String: String] ?? [:]
            for key in ["LANG", "LC_ALL"] {
                environment[key] = locale.isEmpty ? nil : locale
            }
            raw["locale"] = locale
            raw["environment"] = environment
        }
        if let value = patch["arguments"] {
            guard let text = value.string else { throw BridgeFailure("invalid_params", "Expected arguments string") }
            raw["arguments"] = text
        }
        if let value = patch["environment"] {
            raw["environment"] = try environment(value)
        }
        if let value = patch["overrides"] {
            try patchOverrides(value, into: &raw)
        }
    }

    private static func patchOverrides(_ value: JSONValue, into raw: inout [String: Any]) throws {
        if case .null = value {
            raw.removeValue(forKey: "overrides")
        } else {
            guard let object = value.object else { throw BridgeFailure(
                "invalid_params",
                "Expected overrides object or null"
            ) }
            var overrides = raw["overrides"] as? [String: Any] ?? [:]
            for (key, value) in object {
                guard keys.contains(key) else { throw BridgeFailure("invalid_params", "Unknown override: \(key)") }
                if case .null = value {
                    overrides.removeValue(forKey: key)
                    continue
                }
                try validate(value, key: key)
                #if os(Linux)
                if key == "metal4Enabled" ||
                    (key == "graphicsBackend" && ["d3dMetal", "dxmt"].contains(value.string ?? ""))
                    || (key == "enhancedSync" && value.string == "msync")
                    || (key == "resolutionPreset" && value.string == "matchDisplay") {
                    // Imported values survive unrelated edits; new unsupported selections fail explicitly.
                    let previous = try overrides[key].map { try wire($0) }
                    let unchanged = previous == value ||
                        (tagged.contains(key) && (overrides[key] as? [String: Any])?.keys.first == value.string)
                    guard unchanged else { throw BridgeFailure(
                        "capability_unavailable",
                        "This program setting requires the macOS adapter: \(key)"
                    ) }
                }
                #endif
                overrides[key] = try tagged.contains(key)
                    ? [value.textValue(): [String: String]()] : try foundation(value)
            }
            raw["overrides"] = overrides
        }
    }
}

private extension JSONValue {
    func textValue() throws -> String {
        guard let string else { throw BridgeFailure("invalid_params", "Expected string") }
        return string
    }
}
