//
//  LinuxLaunchConfiguration.swift
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
import WhiskyCore

/// The environment and arguments a Linux Wine launch derives from the
/// portable bottle configuration (`Metadata.plist`) and the per-program
/// settings file the GPUI program sheet writes.
///
/// This is the Linux counterpart of WhiskyKit's `constructWineEnvironment`.
/// Only settings with a Linux meaning are applied; macOS-only settings
/// (Metal, D3DMetal, App Nap, Rosetta AVX) are filtered from the Linux schema
/// and ignored here. Layers apply in the same order as on macOS: bottle
/// managed settings, launcher compatibility, bottle user environment, program
/// overrides, then the program's own environment.
public struct LinuxLaunchConfiguration: Sendable, Equatable {
    public var environment: [String: String] = [:]
    public var arguments: [String] = []

    public init(environment: [String: String] = [:], arguments: [String] = []) {
        self.environment = environment
        self.arguments = arguments
    }

    static let dxvkDLLs = ["d3d9", "d3d10core", "d3d11", "dxgi"]

    /// Loads the configuration for `executable` in `container`. Unreadable
    /// optional files fall back to defaults; Wine still starts.
    public static func load(container: URL, executable: URL?) async -> Self {
        let metadataURL = container.appendingPathComponent("Metadata.plist")
        let file = ConfigurationFile(url: metadataURL, locking: HostFileLock())
        let values = (try? await file.values(for: ContainerConfiguration.fields)) ?? [:]
        let bottleEnvironment = (try? await file.strings(at: "environment")) ?? [:]
        let metadata = (try? ProgramSettingsService.load(metadataURL)) ?? [:]
        var program: [String: Any] = [:]
        if let executable {
            let locations = ProgramStorageLayout.locations(for: executable, containerURL: container)
            let source = FileManager.default.fileExists(atPath: locations.identity.path)
                ? locations.identity : locations.legacy
            program = (try? ProgramSettingsService.load(source)) ?? [:]
        }
        return compose(
            values: values,
            bottleEnvironment: bottleEnvironment,
            bottleDLLOverrides: dllOverrides(metadata["customDLLOverrides"]),
            program: program
        )
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func compose(
        values: [String: ConfigurationValue],
        bottleEnvironment: [String: String],
        bottleDLLOverrides: [(String, String)],
        program: [String: Any]
    ) -> Self {
        var environment: [String: String] = ["WINEDEBUG": "fixme-all"]
        var overrides: [(String, String)] = []
        func text(_ key: String) -> String? {
            if case let .text(value) = values[key] { return value }
            return nil
        }
        func flag(_ key: String) -> Bool? {
            if case let .boolean(value) = values[key] { return value }
            return nil
        }

        let programOverrides = program["overrides"] as? [String: Any] ?? [:]
        func overrideText(_ key: String) -> String? {
            if let tags = programOverrides[key] as? [String: Any], tags.count == 1 {
                return tags.keys.first
            }
            return programOverrides[key] as? String
        }
        func overrideFlag(_ key: String) -> Bool? {
            programOverrides[key] as? Bool
        }

        // Synchronization. MSync is the macOS Mach-port primitive; on Linux
        // the closest supported primitive is ESync.
        let sync = overrideText("enhancedSync") ?? text("enhancedSync") ?? "none"
        if sync == "esync" || sync == "msync" {
            environment["WINEESYNC"] = "1"
        }

        // Graphics backend. The Linux runtime ships WineD3D and VKD3D;
        // DXVK applies when its DLLs are installed in the prefix (winetricks).
        let backend = overrideText("graphicsBackend") ?? text("graphicsBackend") ?? "recommended"
        switch backend {
        case "dxvk":
            overrides += dxvkDLLs.map { ($0, "n,b") }
        case "wined3d":
            overrides += dxvkDLLs.map { ($0, "b") }
        default:
            if let dxvk = overrideFlag("dxvk") {
                overrides += dxvkDLLs.map { ($0, dxvk ? "n,b" : "b") }
            }
        }
        if overrideFlag("dxvkAsync") ?? flag("dxvkAsync") ?? true {
            environment["DXVK_ASYNC"] = "1"
        }
        switch overrideText("dxvkHud") ?? text("dxvkHud") ?? "off" {
        case "fps": environment["DXVK_HUD"] = "fps"
        case "partial": environment["DXVK_HUD"] = "devinfo,fps,frametimes"
        case "full": environment["DXVK_HUD"] = "full"
        default: break
        }
        if !(overrideFlag("shaderCacheEnabled") ?? flag("shaderCacheEnabled") ?? true) {
            environment["DXVK_STATE_CACHE"] = "0"
        }

        // Audio. Disabling removes both Linux audio drivers.
        if text("audioDriver") == "disabled" {
            overrides += [("winepulse.drv", ""), ("winealsa.drv", "")]
        }

        // Launcher compatibility: locale and GPU vendor are launcher-managed.
        if flag("launcherCompatibilityMode") == true {
            if let locale = text("launcherLocale"), !locale.isEmpty {
                environment["LANG"] = locale
                environment["LC_ALL"] = locale
            }
        }

        // Controller compatibility uses the same SDL hints as macOS.
        let controller = overrideFlag("controllerCompatibilityMode") ?? flag("controllerCompatibilityMode") ?? false
        if controller {
            if overrideFlag("disableHIDAPI") ?? flag("disableHIDAPI") ?? false {
                environment["SDL_JOYSTICK_HIDAPI"] = "0"
            }
            if overrideFlag("allowBackgroundEvents") ?? flag("allowBackgroundEvents") ?? false {
                environment["SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS"] = "1"
            }
            let mapping = overrideFlag("disableControllerMapping") ?? flag("disableControllerMapping") ?? false
            let labels = overrideFlag("useButtonLabels") ?? flag("useButtonLabels") ?? false
            environment["SDL_GAMECONTROLLER_USE_BUTTON_LABELS"] = mapping || labels ? "1" : "0"
        }

        // DLL overrides: bottle custom entries, then program entries; the
        // last entry for a DLL wins.
        overrides += bottleDLLOverrides
        overrides += dllOverrides(programOverrides["dllOverrides"])

        // User environment: bottle first, then the program (which carries
        // the program locale as LANG/LC_ALL).
        for (key, value) in bottleEnvironment where validKey(key) {
            environment[key] = value
        }
        let programEnvironment = program["environment"] as? [String: String] ?? [:]
        for (key, value) in programEnvironment where validKey(key) {
            environment[key] = value
        }
        // A layer that only chose LANG must not lose to an inherited LC_ALL.
        if let language = environment["LANG"], environment["LC_ALL"] == nil {
            environment["LC_ALL"] = language
        }

        if !overrides.isEmpty {
            var order: [String] = []
            var modes: [String: String] = [:]
            for (dll, mode) in overrides {
                if modes[dll] == nil { order.append(dll) }
                modes[dll] = mode
            }
            let composed = order.map { "\($0)=\(modes[$0] ?? "")" }
            if let existing = environment["WINEDLLOVERRIDES"], !existing.isEmpty {
                // A user-written variable stays authoritative for its DLLs.
                environment["WINEDLLOVERRIDES"] = (composed + [existing]).joined(separator: ";")
            } else {
                environment["WINEDLLOVERRIDES"] = composed.joined(separator: ";")
            }
        }

        let arguments = splitArguments(program["arguments"] as? String ?? "")
        return Self(environment: environment, arguments: arguments)
    }

    static func dllOverrides(_ raw: Any?) -> [(String, String)] {
        guard let items = raw as? [Any] else { return [] }
        return items.compactMap { item in
            guard let entry = item as? [String: Any],
                  let name = entry["dllName"] as? String, !name.isEmpty,
                  !name.contains(where: { $0 == "=" || $0 == ";" || $0 == "," || $0.isWhitespace }),
                  let mode = entry["mode"] as? String,
                  ["n,b", "b,n", "n", "b", ""].contains(mode)
            else { return nil }
            return (name, mode)
        }
    }

    static func validKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first,
              first == "_" || (first.isASCII && CharacterSet.letters.contains(first))
        else { return false }
        return key.unicodeScalars.allSatisfy {
            $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0))
        }
    }

    /// Splits a program argument string the way a POSIX shell would for
    /// words, single quotes, double quotes and backslash escapes, without
    /// any expansion.
    public static func splitArguments(_ text: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaping = false
        for character in text {
            if escaping {
                current.append(character)
                escaping = false
                inWord = true
                continue
            }
            if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "\\", open == "\"" {
                    escaping = true
                } else {
                    current.append(character)
                }
                continue
            }
            switch character {
            case "\\":
                escaping = true
            case "\"", "'":
                quote = character
                inWord = true
            case " ", "\t", "\n", "\r":
                if inWord {
                    arguments.append(current)
                    current = ""
                    inWord = false
                }
            default:
                current.append(character)
                inWord = true
            }
        }
        if inWord {
            arguments.append(current)
        }
        return arguments
    }
}
