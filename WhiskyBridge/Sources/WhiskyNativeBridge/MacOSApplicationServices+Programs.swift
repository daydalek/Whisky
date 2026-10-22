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
}

extension MacOSApplicationServices {
    func programsCall(
        _ method: String,
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) async throws -> JSONValue {
        switch method {
        case "programs.settings.read", "programs.settings.set":
            let target = try programTarget(params, workspace: workspace)
            return try await ProgramSettingsService.call(
                method, params: params, workspace: workspace, defaults: defaultsPayload(target.bottle)
            )
        case "programs.history.read", "programs.history.delete":
            return try ProgramHistoryService.call(
                method, params: params, workspace: workspace, logsDirectory: Wine.logsFolder
            )
        case "programs.shortcut.create":
            return try await createShortcut(params, target: programTarget(params, workspace: workspace))
        case "programs.run":
            return try runProgram(params, workspace: workspace)
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
        return ProgramTarget(
            container: container,
            executable: executable,
            bottle: bottle,
            name: executable.lastPathComponent
        )
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
