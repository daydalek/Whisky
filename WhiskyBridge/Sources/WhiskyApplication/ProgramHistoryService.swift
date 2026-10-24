//
//  ProgramHistoryService.swift
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

/// Operates on the existing per-program run-history plist, including imported history.
@MainActor
public enum ProgramHistoryService {
    public static let methods = ["programs.history.read", "programs.history.delete"]

    public static func call(
        _ method: String, params: [String: JSONValue], workspace: ApplicationWorkspace,
        logsDirectory: URL = defaultLogsDirectory()
    ) throws -> JSONValue {
        guard methods.contains(method) else { throw BridgeFailure("method_unavailable", "Unknown history method") }
        let container = try workspace.resolve(params)
        let executable = try params.path("executable")
        guard executable.pathExtension.lowercased() == "exe" else { throw BridgeFailure(
            "invalid_params",
            "Expected .exe path"
        ) }
        let url = container.appendingPathComponent("Program Settings")
            .appendingPathComponent(executable.lastPathComponent).appendingPathExtension("run-history.plist")
        return try HostFileLock().withExclusiveLock(at: url.appendingPathExtension("lock")) {
            var raw = try ProgramSettingsService.load(url)
            guard raw["entries"] == nil || raw["entries"] is [[String: Any]] else {
                throw BridgeFailure("invalid_settings", "Invalid history entries")
            }
            var entries = raw["entries"] as? [[String: Any]] ?? []
            // Validate before mutation so malformed imported history stays recoverable.
            _ = try entries.map { try payload($0, logsDirectory: logsDirectory) }
            if method == "programs.history.delete" {
                let removed: [[String: Any]]
                if let value = params["runID"] {
                    guard let id = value.string.flatMap(UUID.init(uuidString:)),
                          let index = entries
                          .firstIndex(where: { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) == id })
                    else { throw BridgeFailure("invalid_params", "Unknown run ID") }
                    removed = [entries.remove(at: index)]
                } else {
                    removed = entries
                    entries = []
                }
                raw["entries"] = entries
                let data = try PropertyListSerialization.data(fromPropertyList: raw, format: .xml, options: 0)
                try data.write(to: url, options: .atomic)
                for entry in removed {
                    guard let name = entry["logFileName"] as? String else { continue }
                    let file = logsDirectory.appendingPathComponent(name)
                    // Imported metadata can only remove regular logs inside the configured log directory.
                    let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    if values?.isRegularFile == true, values?.isSymbolicLink == false {
                        try? FileManager.default.removeItem(at: file)
                    }
                }
            }
            return try .object([
                "container": .string(container.path), "executable": .string(executable.path),
                "programName": .string(executable.lastPathComponent),
                "entries": .array(entries.map { try payload($0, logsDirectory: logsDirectory) })
            ])
        }
    }

    private static func payload(_ entry: [String: Any], logsDirectory: URL) throws -> JSONValue {
        guard let id = entry["id"] as? String, UUID(uuidString: id) != nil,
              let name = entry["logFileName"] as? String, !name.isEmpty,
              !name.contains("/"), !name.contains("\\"), !name.contains("\0"), name.hasSuffix(".log"),
              let program = entry["programName"] as? String, let start = entry["startTime"] as? Date
        else { throw BridgeFailure("invalid_settings", "Invalid run history record") }
        var result: [String: JSONValue] = [
            "id": .string(id), "programName": .string(program), "logFileName": .string(name),
            "logPath": .string(logsDirectory.appendingPathComponent(name).path),
            "startTime": .number(start.timeIntervalSince1970),
            "hasWineDebugOutput": .bool(entry["hasWineDebugOutput"] as? Bool ?? false)
        ]
        if let end = entry["endTime"] as? Date {
            result["endTime"] = .number(end.timeIntervalSince1970)
            result["duration"] = .number(end.timeIntervalSince(start))
        }
        if let code = entry["exitCode"] as? NSNumber {
            result["exitCode"] = .integer(code.int64Value)
        }
        return .object(result)
    }

    public static func defaultLogsDirectory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let base = environment["XDG_STATE_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? home.appendingPathComponent(".local/state")
        return base.appendingPathComponent("whisky/logs")
    }
}
