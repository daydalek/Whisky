//
//  LinuxProgramRunHistory.swift
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
import WhiskyBridgeProtocol

/// Native-compatible history records, paired with unique durable log files.
struct LinuxProgramRunHistory: Sendable {
    let id: UUID
    let container: URL
    let executable: URL
    let log: URL

    static func begin(container: URL, executable: URL, logs: URL, at date: Date = Date()) throws -> Self {
        let run = Self(
            id: UUID(),
            container: container,
            executable: executable,
            log: logs.appendingPathComponent("\(UUID().uuidString).log")
        )
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data().write(to: run.log, options: .atomic)
        try run.update { entries in
            entries.append([
                "id": run.id.uuidString,
                "programName": executable.lastPathComponent,
                "logFileName": run.log.lastPathComponent,
                "startTime": date,
                "hasWineDebugOutput": true
            ])
            // History pruning preserves logs so another live reader can finish exporting them.
            if entries.count > 100 {
                entries.removeFirst(entries.count - 100)
            }
        }
        return run
    }

    func finish(exitCode: Int32, at date: Date = Date()) throws {
        try update { entries in
            guard let index = entries.firstIndex(where: { $0["id"] as? String == id.uuidString }) else { return }
            entries[index]["endTime"] = date
            entries[index]["exitCode"] = exitCode
        }
    }

    private func update(_ operation: (inout [[String: Any]]) throws -> Void) throws {
        let url = container.appendingPathComponent("Program Settings")
            .appendingPathComponent(executable.lastPathComponent + ".run-history.plist")
        try HostFileLock().withExclusiveLock(at: url.appendingPathExtension("lock")) {
            var document = try ProgramSettingsService.load(url)
            guard document["entries"] == nil || document["entries"] is [[String: Any]] else {
                throw BridgeFailure("invalid_settings", "Run history is unreadable; preserve it before recovery")
            }
            var entries = document["entries"] as? [[String: Any]] ?? []
            try operation(&entries)
            document["entries"] = entries
            try PropertyListSerialization.data(fromPropertyList: document, format: .xml, options: 0)
                .write(to: url, options: .atomic)
        }
    }
}
