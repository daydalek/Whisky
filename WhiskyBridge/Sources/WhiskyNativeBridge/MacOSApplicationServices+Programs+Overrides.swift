//
//  MacOSApplicationServices+Programs+Overrides.swift
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

import AppKit
import Foundation
import WhiskyBridgeProtocol
import WhiskyCore
import WhiskyKit

extension MacOSApplicationServices {
    // MARK: - Patch

    func applySettingsPatch(
        _ patch: [String: JSONValue],
        to settings: inout ProgramSettings
    ) throws {
        let known: Set = ["locale", "arguments", "environment", "overrides"]
        if let unknown = patch.keys.first(where: { !known.contains($0) }) {
            throw BridgeFailure("invalid_params", "Unknown program setting: \(unknown)")
        }
        if let value = patch["locale"] {
            guard let raw = value.string, let locale = Locales(rawValue: raw) else {
                throw BridgeFailure("invalid_params", "Unknown locale")
            }
            settings.applyLocalePreset(locale)
        }
        if let value = patch["arguments"] {
            guard let arguments = value.string else {
                throw BridgeFailure("invalid_params", "Expected a string: arguments")
            }
            settings.arguments = arguments
        }
        if let value = patch["environment"] {
            settings.environment = try environment(from: value)
        }
        if let value = patch["overrides"] {
            try applyOverridesPatch(value, to: &settings)
        }
    }

    private func applyOverridesPatch(_ value: JSONValue, to settings: inout ProgramSettings) throws {
        guard case let .object(object) = value else {
            if case .null = value {
                settings.overrides = nil
                return
            }
            throw BridgeFailure("invalid_params", "Expected an object or null: overrides")
        }
        var overrides = settings.overrides ?? ProgramOverrides()
        for (key, value) in object {
            try applyOverride(key, value, to: &overrides)
        }
        settings.overrides = overrides
    }

    private func applyOverride(
        _ key: String,
        _ value: JSONValue,
        to overrides: inout ProgramOverrides
    ) throws {
        if try applyGraphicsOverride(key, value, to: &overrides) {
            return
        }
        if try applyInputOverride(key, value, to: &overrides) {
            return
        }
        if try applyDisplayOverride(key, value, to: &overrides) {
            return
        }
        if try applyMiscOverride(key, value, to: &overrides) {
            return
        }
        throw BridgeFailure("invalid_params", "Unknown override: \(key)")
    }

    private func applyGraphicsOverride(
        _ key: String,
        _ value: JSONValue,
        to overrides: inout ProgramOverrides
    ) throws -> Bool {
        switch key {
        case "graphicsBackend":
            overrides.graphicsBackend = try optional(value) { raw in
                guard let text = raw.string, let backend = GraphicsBackend(rawValue: text) else {
                    throw BridgeFailure("invalid_params", "Unknown graphics backend")
                }
                return backend
            }
        case "dxvk": overrides.dxvk = try optional(value, bool)
        case "dxvkAsync": overrides.dxvkAsync = try optional(value, bool)
        case "dxvkHud": overrides.dxvkHud = try optional(value, hud)
        case "metal4Enabled": overrides.metal4Enabled = try optional(value, bool)
        default: return false
        }
        return true
    }

    private func applyInputOverride(
        _ key: String,
        _ value: JSONValue,
        to overrides: inout ProgramOverrides
    ) throws -> Bool {
        switch key {
        case "controllerCompatibilityMode": overrides.controllerCompatibilityMode = try optional(value, bool)
        case "disableHIDAPI": overrides.disableHIDAPI = try optional(value, bool)
        case "allowBackgroundEvents": overrides.allowBackgroundEvents = try optional(value, bool)
        case "disableControllerMapping": overrides.disableControllerMapping = try optional(value, bool)
        case "useButtonLabels": overrides.useButtonLabels = try optional(value, bool)
        default: return false
        }
        return true
    }

    private func applyDisplayOverride(
        _ key: String,
        _ value: JSONValue,
        to overrides: inout ProgramOverrides
    ) throws -> Bool {
        switch key {
        case "virtualDesktopEnabled": overrides.virtualDesktopEnabled = try optional(value, bool)
        case "resolutionPreset":
            overrides.resolutionPreset = try optional(value) { raw in
                guard let text = raw.string, let preset = ResolutionPreset(rawValue: text) else {
                    throw BridgeFailure("invalid_params", "Unknown resolution preset")
                }
                return preset
            }
        case "customResolutionWidth":
            overrides.customResolutionWidth = try optional(value) { raw in
                try resolutionDimension(raw)
            }
        case "customResolutionHeight":
            overrides.customResolutionHeight = try optional(value) { raw in
                try resolutionDimension(raw)
            }
        default: return false
        }
        return true
    }

    private func applyMiscOverride(
        _ key: String,
        _ value: JSONValue,
        to overrides: inout ProgramOverrides
    ) throws -> Bool {
        switch key {
        case "enhancedSync": overrides.enhancedSync = try optional(value, sync)
        case "shaderCacheEnabled": overrides.shaderCacheEnabled = try optional(value, bool)
        case "dllOverrides": overrides.dllOverrides = try optional(value, dllOverrides)
        case "taggedVerbs": overrides.taggedVerbs = try optional(value, stringArray)
        default: return false
        }
        return true
    }

    private func optional<T>(
        _ value: JSONValue,
        _ parse: (JSONValue) throws -> T
    ) throws -> T? {
        if case .null = value {
            return nil
        }
        return try parse(value)
    }

    private func bool(_ value: JSONValue) throws -> Bool {
        guard let result = value.bool else {
            throw BridgeFailure("invalid_params", "Expected a boolean override value")
        }
        return result
    }

    private func hud(_ value: JSONValue) throws -> DXVKHUD {
        switch value.string {
        case "full": return .full
        case "partial": return .partial
        case "fps": return .fps
        case "off": return .off
        default: throw BridgeFailure("invalid_params", "Unknown DXVK HUD mode")
        }
    }

    private func sync(_ value: JSONValue) throws -> EnhancedSync {
        switch value.string {
        case "none": return .none
        case "esync": return .esync
        case "msync": return .msync
        default: throw BridgeFailure("invalid_params", "Unknown sync mode")
        }
    }

    private func resolutionDimension(_ value: JSONValue) throws -> Int {
        guard let raw = value.integer, let dimension = Int(exactly: raw), (200 ... 16_384).contains(dimension)
        else { throw BridgeFailure("invalid_params", "Resolution dimension is out of range") }
        return dimension
    }

    private func stringArray(_ value: JSONValue) throws -> [String] {
        guard case let .array(values) = value else {
            throw BridgeFailure("invalid_params", "Expected an array of strings")
        }
        return try values.map { item in
            guard let text = item.string, !text.isEmpty else {
                throw BridgeFailure("invalid_params", "Expected nonempty strings")
            }
            return text
        }
    }

    private func dllOverrides(_ value: JSONValue) throws -> [DLLOverrideEntry] {
        guard case let .array(values) = value else {
            throw BridgeFailure("invalid_params", "Expected an array of DLL overrides")
        }
        return try values.map { item in
            guard let object = item.object,
                  let name = object["dllName"]?.string,
                  let rawMode = object["mode"]?.string,
                  let mode = DLLOverrideMode(rawValue: rawMode),
                  !name.isEmpty,
                  name.utf8.count <= 64,
                  !name.contains(where: { $0.isWhitespace || $0 == "=" || $0 == "," || $0 == "\0" })
            else { throw BridgeFailure("invalid_params", "Invalid DLL override") }
            return DLLOverrideEntry(dllName: name, mode: mode)
        }
    }

    private func environment(from value: JSONValue) throws -> [String: String] {
        guard case let .object(object) = value else {
            throw BridgeFailure("invalid_params", "Expected an object: environment")
        }
        var result: [String: String] = [:]
        for (key, item) in object {
            guard !key.isEmpty, !key.contains("="), !key.contains("\0"),
                  key.utf8.count <= 256,
                  let text = item.string, !text.contains("\0"), text.utf8.count <= 16_384
            else { throw BridgeFailure("invalid_params", "Invalid environment variable") }
            result[key] = text
        }
        return result
    }

    func overridesPayload(_ overrides: ProgramOverrides) -> JSONValue {
        var payload = graphicsPayload(overrides)
        payload.merge(inputPayload(overrides)) { _, new in new }
        payload.merge(displayPayload(overrides)) { _, new in new }
        if let value = overrides.enhancedSync {
            payload["enhancedSync"] = .string(Self.syncRaw(value))
        }
        if let value = overrides.dllOverrides {
            payload["dllOverrides"] = Self.dllPayload(value)
        }
        if let value = overrides.taggedVerbs {
            payload["taggedVerbs"] = .array(value.map(JSONValue.string))
        }
        return .object(payload)
    }

    private func graphicsPayload(_ overrides: ProgramOverrides) -> [String: JSONValue] {
        var payload: [String: JSONValue] = [:]
        if let value = overrides.graphicsBackend {
            payload["graphicsBackend"] = .string(value.rawValue)
        }
        if let value = overrides.dxvk {
            payload["dxvk"] = .bool(value)
        }
        if let value = overrides.dxvkAsync {
            payload["dxvkAsync"] = .bool(value)
        }
        if let value = overrides.dxvkHud {
            payload["dxvkHud"] = .string(Self.hudRaw(value))
        }
        if let value = overrides.metal4Enabled {
            payload["metal4Enabled"] = .bool(value)
        }
        if let value = overrides.shaderCacheEnabled {
            payload["shaderCacheEnabled"] = .bool(value)
        }
        return payload
    }

    private func inputPayload(_ overrides: ProgramOverrides) -> [String: JSONValue] {
        var payload: [String: JSONValue] = [:]
        if let value = overrides.controllerCompatibilityMode {
            payload["controllerCompatibilityMode"] = .bool(value)
        }
        if let value = overrides.disableHIDAPI {
            payload["disableHIDAPI"] = .bool(value)
        }
        if let value = overrides.allowBackgroundEvents {
            payload["allowBackgroundEvents"] = .bool(value)
        }
        if let value = overrides.disableControllerMapping {
            payload["disableControllerMapping"] = .bool(value)
        }
        if let value = overrides.useButtonLabels {
            payload["useButtonLabels"] = .bool(value)
        }
        return payload
    }

    private func displayPayload(_ overrides: ProgramOverrides) -> [String: JSONValue] {
        var payload: [String: JSONValue] = [:]
        if let value = overrides.virtualDesktopEnabled {
            payload["virtualDesktopEnabled"] = .bool(value)
        }
        if let value = overrides.resolutionPreset {
            payload["resolutionPreset"] = .string(value.rawValue)
        }
        if let value = overrides.customResolutionWidth {
            payload["customResolutionWidth"] = .integer(Int64(value))
        }
        if let value = overrides.customResolutionHeight {
            payload["customResolutionHeight"] = .integer(Int64(value))
        }
        return payload
    }

    static func dllPayload(_ entries: [DLLOverrideEntry]) -> JSONValue {
        .array(entries.map { entry in
            .object([
                "dllName": .string(entry.dllName),
                "mode": .string(entry.mode.rawValue)
            ])
        })
    }

    static func hudRaw(_ hud: DXVKHUD) -> String {
        switch hud {
        case .full: "full"
        case .partial: "partial"
        case .fps: "fps"
        case .off: "off"
        }
    }

    static func syncRaw(_ sync: EnhancedSync) -> String {
        switch sync {
        case .none: "none"
        case .esync: "esync"
        case .msync: "msync"
        }
    }

    func writeOverrides(_ overrides: ProgramOverrides, into raw: inout [String: Any]) {
        Self.setOrRemove(&raw, "graphicsBackend", overrides.graphicsBackend?.rawValue)
        Self.setOrRemove(&raw, "dxvk", overrides.dxvk)
        Self.setOrRemove(&raw, "dxvkAsync", overrides.dxvkAsync)
        Self.setOrRemove(&raw, "dxvkHud", overrides.dxvkHud.map(Self.hudRaw))
        Self.setOrRemove(&raw, "enhancedSync", overrides.enhancedSync.map(Self.syncRaw))
        Self.setOrRemove(&raw, "metal4Enabled", overrides.metal4Enabled)
        Self.setOrRemove(&raw, "shaderCacheEnabled", overrides.shaderCacheEnabled)
        Self.setOrRemove(&raw, "controllerCompatibilityMode", overrides.controllerCompatibilityMode)
        Self.setOrRemove(&raw, "disableHIDAPI", overrides.disableHIDAPI)
        Self.setOrRemove(&raw, "allowBackgroundEvents", overrides.allowBackgroundEvents)
        Self.setOrRemove(&raw, "disableControllerMapping", overrides.disableControllerMapping)
        Self.setOrRemove(&raw, "useButtonLabels", overrides.useButtonLabels)
        Self.setOrRemove(&raw, "virtualDesktopEnabled", overrides.virtualDesktopEnabled)
        Self.setOrRemove(&raw, "resolutionPreset", overrides.resolutionPreset?.rawValue)
        Self.setOrRemove(&raw, "customResolutionWidth", overrides.customResolutionWidth)
        Self.setOrRemove(&raw, "customResolutionHeight", overrides.customResolutionHeight)
        if let entries = overrides.dllOverrides {
            raw["dllOverrides"] = entries.map { ["dllName": $0.dllName, "mode": $0.mode.rawValue] }
        } else {
            raw.removeValue(forKey: "dllOverrides")
        }
        if let verbs = overrides.taggedVerbs {
            raw["taggedVerbs"] = verbs
        } else {
            raw.removeValue(forKey: "taggedVerbs")
        }
    }

    private static func setOrRemove(_ raw: inout [String: Any], _ key: String, _ value: Any?) {
        if let value {
            raw[key] = value
        } else {
            raw.removeValue(forKey: key)
        }
    }
}
