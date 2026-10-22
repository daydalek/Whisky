//
//  MacOSApplicationServices+Programs.swift
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
import WhiskyApplication
import WhiskyBridgeProtocol
import WhiskyCore
import WhiskyKit

struct ProgramTarget {
    let container: URL
    let executable: URL
    let bottle: Bottle
    let name: String
    let identity: URL
    let legacy: URL
}

struct LoadedProgramSettings {
    var raw: [String: Any]
    var settings: ProgramSettings
}

extension MacOSApplicationServices {
    func programsCall(
        _ method: String,
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) async throws -> JSONValue {
        switch method {
        case "programs.settings.read":
            let target = try programTarget(params, workspace: workspace)
            return try settingsPayload(for: target, loaded: loadSettings(for: target))
        case "programs.settings.set":
            let target = try programTarget(params, workspace: workspace)
            return try settingsPayload(for: target, loaded: saveSettings(params, for: target))
        case "programs.history.read":
            return try historyPayload(for: programTarget(params, workspace: workspace))
        case "programs.history.delete":
            return try deleteHistory(params, target: programTarget(params, workspace: workspace))
        case "programs.shortcut.create":
            return try await createShortcut(params, target: programTarget(params, workspace: workspace))
        default:
            throw BridgeFailure("method_unavailable", "Native method is unavailable")
        }
    }

    private func programTarget(
        _ params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) throws -> ProgramTarget {
        let container = try workspace.resolve(params)
        guard let bottle = bottle(container) else {
            throw BridgeFailure("invalid_container", "Wine settings are unreadable")
        }
        let executable = try params.path("executable")
        guard executable.pathExtension.lowercased() == "exe" else {
            throw BridgeFailure("invalid_params", "Expected an .exe path: executable")
        }
        let locations = ProgramStorageLayout.locations(for: executable, containerURL: container)
        return ProgramTarget(
            container: container,
            executable: executable,
            bottle: bottle,
            name: executable.lastPathComponent,
            identity: locations.identity,
            legacy: locations.legacy
        )
    }

    // MARK: - Settings read/write

    private func loadSettings(for target: ProgramTarget) throws -> LoadedProgramSettings {
        let source: URL? = if FileManager.default.fileExists(atPath: target.identity.path) {
            target.identity
        } else if FileManager.default.fileExists(atPath: target.legacy.path) {
            target.legacy
        } else {
            nil
        }
        guard let source else {
            return LoadedProgramSettings(raw: [:], settings: ProgramSettings())
        }
        guard try (source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 16 * 1_024 * 1_024
        else { throw BridgeFailure("invalid_settings", "Program settings are too large") }
        let data = try Data(contentsOf: source)
        guard let raw = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any]
        else { throw BridgeFailure("invalid_settings", "Program settings are unreadable") }
        do {
            return try LoadedProgramSettings(
                raw: raw,
                settings: PropertyListDecoder().decode(ProgramSettings.self, from: data)
            )
        } catch {
            throw BridgeFailure("invalid_settings", "Program settings are unreadable: \(error.localizedDescription)")
        }
    }

    private func saveSettings(
        _ params: [String: JSONValue],
        for target: ProgramTarget
    ) throws -> LoadedProgramSettings {
        guard let patch = params["patch"]?.object else {
            throw BridgeFailure("invalid_params", "Expected an object: patch")
        }
        var loaded = try loadSettings(for: target)
        try applySettingsPatch(patch, to: &loaded.settings)
        loaded.raw["locale"] = loaded.settings.locale.rawValue
        loaded.raw["arguments"] = loaded.settings.arguments
        loaded.raw["environment"] = loaded.settings.environment
        if let overrides = loaded.settings.overrides {
            var rawOverrides = loaded.raw["overrides"] as? [String: Any] ?? [:]
            writeOverrides(overrides, into: &rawOverrides)
            loaded.raw["overrides"] = rawOverrides
        } else {
            loaded.raw.removeValue(forKey: "overrides")
        }
        try writeSettings(loaded.raw, to: target.identity)
        return loaded
    }

    private func writeSettings(_ raw: [String: Any], to url: URL) throws {
        let lock = url.appendingPathExtension("lock")
        try HostFileLock().withExclusiveLock(at: lock) {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard let data = try? PropertyListSerialization.data(
                fromPropertyList: raw,
                format: .xml,
                options: 0
            )
            else { throw BridgeFailure("invalid_settings", "Program settings cannot be encoded") }
            try data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Encoding

    private func settingsPayload(
        for target: ProgramTarget,
        loaded: LoadedProgramSettings
    ) throws -> JSONValue {
        var payload: [String: JSONValue] = [
            "container": .string(target.container.path),
            "executable": .string(target.executable.path),
            "programName": .string(target.name),
            "locale": .string(loaded.settings.locale.rawValue),
            "arguments": .string(loaded.settings.arguments),
            "environment": .object(loaded.settings.environment.mapValues(JSONValue.string)),
            "defaults": defaultsPayload(target.bottle),
            "available": .bool(FileManager.default.fileExists(atPath: target.executable.path))
        ]
        if let overrides = loaded.settings.overrides {
            payload["overrides"] = overridesPayload(overrides)
        } else {
            payload["overrides"] = .null
        }
        if let url = loaded.settings.lastLogFileURL {
            payload["lastLogFile"] = .string(url.path)
        }
        if let date = loaded.settings.lastDiagnosisDate {
            payload["lastDiagnosisDate"] = .integer(Int64(date.timeIntervalSince1970))
        }
        return .object(payload)
    }

    private func defaultsPayload(_ bottle: Bottle) -> JSONValue {
        let settings = bottle.settings
        return .object([
            "graphicsBackend": .string(settings.graphicsBackend.rawValue),
            "dxvkAsync": .bool(settings.dxvkAsync),
            "dxvkHud": .string(Self.hudRaw(settings.dxvkHud)),
            "metal4Enabled": .bool(settings.metal4Enabled),
            "enhancedSync": .string(Self.syncRaw(settings.enhancedSync)),
            "shaderCacheEnabled": .bool(settings.shaderCacheEnabled),
            "controllerCompatibilityMode": .bool(settings.controllerCompatibilityMode),
            "disableHIDAPI": .bool(settings.disableHIDAPI),
            "allowBackgroundEvents": .bool(settings.allowBackgroundEvents),
            "disableControllerMapping": .bool(settings.disableControllerMapping),
            "useButtonLabels": .bool(settings.useButtonLabels),
            "virtualDesktopEnabled": .bool(settings.virtualDesktopEnabled),
            "resolutionPreset": .string(settings.resolutionPreset.rawValue),
            "customResolutionWidth": .integer(Int64(settings.customResolutionWidth)),
            "customResolutionHeight": .integer(Int64(settings.customResolutionHeight)),
            "dllOverrides": Self.dllPayload(settings.dllOverrides)
        ])
    }
}
