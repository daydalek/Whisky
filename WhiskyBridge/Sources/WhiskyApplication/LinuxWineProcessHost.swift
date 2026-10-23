//
//  LinuxWineProcessHost.swift
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

/// `ProcessSnapshotProviding` for a Linux Wine runtime, using the runtime's
/// built-in `tasklist.exe /FO CSV /NH` and `taskkill.exe` and guarding the
/// query behind `wineserver -k0` so polling an idle bottle never boots a
/// server or exceeds the frontend's call timeout.
@MainActor
public final class LinuxWineProcessHost: ProcessSnapshotProviding {
    public let host: LinuxWineHost

    private nonisolated static let services: Set<String> = [
        "services.exe", "winedevice.exe", "plugplay.exe", "svchost.exe",
        "rpcss.exe", "tabtip.exe", "conhost.exe"
    ]
    private nonisolated static let system: Set<String> = [
        "explorer.exe", "start.exe", "csrss.exe", "wininit.exe",
        "winlogon.exe", "lsass.exe", "smss.exe"
    ]

    public init(host: LinuxWineHost) {
        self.host = host
    }

    public func listProcesses(in container: URL) async throws -> [ProcessRecord] {
        guard await host.serverRunning(prefix: container) else { return [] }
        let result = try await host.run(
            host.loader,
            arguments: ["tasklist.exe", "/FO", "CSV", "/NH"],
            prefix: container,
            environment: ["WINEDEBUG": "-all"],
            timeout: .seconds(4)
        )
        guard !result.timedOut, result.status == 0 else { return [] }
        return Self.parseTasklist(result.output)
    }

    public func terminateProcess(in container: URL, pid: Int32, force: Bool) async throws {
        var arguments = ["taskkill.exe", "/PID", String(pid)]
        if force {
            arguments.append("/F")
        }
        _ = try? await host.run(
            host.loader,
            arguments: arguments,
            prefix: container,
            environment: ["WINEDEBUG": "-all"],
            timeout: .seconds(4)
        )
    }

    public func terminateAllProcesses(in container: URL) async throws {
        _ = try? await host.run(
            host.wineserver,
            arguments: ["-k"],
            prefix: container,
            timeout: .seconds(5)
        )
    }

    /// Parses quoted CSV rows produced by `tasklist.exe /FO CSV`.
    public nonisolated static func parseTasklist(_ output: String) -> [ProcessRecord] {
        var records: [ProcessRecord] = []
        for line in output.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let fields = csvFields(String(line))
            guard fields.count >= 5, fields[1] != "PID", let pid = Int32(fields[1]) else { continue }
            let name = fields[0]
            let lower = name.lowercased()
            guard lower != "tasklist.exe" else { continue }
            let kind = services.contains(lower) ? "service" : system.contains(lower) ? "system" : "app"
            records.append(ProcessRecord(
                pid: pid,
                name: name,
                memory: fields[4],
                kind: kind,
                source: "untracked"
            ))
        }
        return records
    }

    private nonisolated static func csvFields(_ line: String) -> [String] {
        var fields: [String] = []
        var field = ""
        var quoted = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            let next = line.index(after: index)
            if character == "\"" {
                if quoted, next < line.endIndex, line[next] == "\"" {
                    field.append(character)
                    index = line.index(after: next)
                    continue
                }
                quoted.toggle()
            } else if character == ",", !quoted {
                fields.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
                field = ""
            } else {
                field.append(character)
            }
            index = next
        }
        guard !quoted else { return [] }
        fields.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
        return fields
    }
}
