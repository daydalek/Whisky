//
//  MacOSApplicationServices+Programs+History.swift
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

extension MacOSApplicationServices {
    // MARK: - Run history

    func historyPayload(for target: ProgramTarget) throws -> JSONValue {
        let history = RunLogStore.load(for: target.name, in: target.container)
        let logsFolder = Wine.logsFolder
        let entries: [JSONValue] = history.entries.map { entry in
            var payload: [String: JSONValue] = [
                "id": .string(entry.id.uuidString),
                "programName": .string(entry.programName),
                "logFileName": .string(entry.logFileName),
                "logPath": .string(logsFolder.appending(path: entry.logFileName).path),
                "startTime": .integer(Int64(entry.startTime.timeIntervalSince1970)),
                "hasWineDebugOutput": .bool(entry.hasWineDebugOutput)
            ]
            if let end = entry.endTime {
                payload["endTime"] = .integer(Int64(end.timeIntervalSince1970))
                payload["duration"] = .number(end.timeIntervalSince(entry.startTime))
            }
            if let code = entry.exitCode {
                payload["exitCode"] = .integer(Int64(code))
            }
            return .object(payload)
        }
        return .object([
            "container": .string(target.container.path),
            "executable": .string(target.executable.path),
            "programName": .string(target.name),
            "entries": .array(entries)
        ])
    }

    func deleteHistory(
        _ params: [String: JSONValue],
        target: ProgramTarget
    ) throws -> JSONValue {
        var history = RunLogStore.load(for: target.name, in: target.container)
        let removed: [RunLogEntry]
        if let rawID = params["runID"]?.string {
            guard let id = UUID(uuidString: rawID), let entry = history.deleteEntry(id: id) else {
                throw BridgeFailure("invalid_params", "Unknown run ID")
            }
            removed = [entry]
        } else {
            removed = history.entries
            history.entries = []
        }
        RunLogStore.save(history, for: target.name, in: target.container)
        let logsFolder = Wine.logsFolder
        for entry in removed {
            try? FileManager.default.removeItem(at: logsFolder.appending(path: entry.logFileName))
        }
        return try historyPayload(for: target)
    }

    // MARK: - Shortcut

    func createShortcut(
        _ params: [String: JSONValue],
        target: ProgramTarget
    ) async throws -> JSONValue {
        guard FileManager.default.fileExists(atPath: target.executable.path) else {
            throw BridgeFailure("file_missing", "The selected executable is unavailable")
        }
        let destination = try params.path("destination")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { throw BridgeFailure("invalid_params", "Expected an existing destination directory") }

        let name: String = if let custom = params["name"]?.string {
            custom
        } else {
            target.executable.deletingPathExtension().lastPathComponent
        }
        guard !name.isEmpty, name.utf8.count <= 128,
              !name.contains("/"), !name.contains(":"), !name.contains("\0")
        else { throw BridgeFailure("invalid_params", "Invalid shortcut name") }
        let appURL = destination.appendingPathComponent(name).appendingPathExtension("app")
        guard !FileManager.default.fileExists(atPath: appURL.path) else {
            throw BridgeFailure("destination_exists", "A shortcut already exists at that path")
        }

        let liveTarget = ShortcutCreator.liveTarget(for: target.executable, bottle: target.bottle)
        let launchScript = ShortcutCreator.liveLaunchScript(for: liveTarget)
        try ShortcutCreator.createShortcutBundle(at: appURL, launchScript: launchScript, name: name)
        let icon = await IconCache.shared.iconOrFallback(for: target.executable)
        NSWorkspace.shared.setIcon(icon, forFile: appURL.path, options: [])
        NSWorkspace.shared.activateFileViewerSelecting([appURL])
        return .object([
            "path": .string(appURL.path),
            "name": .string(name)
        ])
    }
}
