//
//  Wine+ProcessManagement.swift
//  WhiskyKit
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
import os.log

private let processLogger = Logger(
    subsystem: Bundle.whiskyBundleIdentifier,
    category: "Wine.ProcessManagement"
)

// MARK: - Wine Process Management Helpers

public extension Wine {
    /// Probes whether a wineserver is currently running for the given bottle.
    ///
    /// Uses `wineserver -k0` which sends signal 0 (a no-op) to the wineserver.
    /// Exit code 0 means the wineserver is alive; any other code (or error)
    /// means it is not running. This does **not** spawn a new wineserver.
    ///
    /// - Parameter bottle: The bottle whose wineserver to probe.
    /// - Returns: `true` if the wineserver is active, `false` otherwise.
    @MainActor
    static func isWineserverRunning(for bottle: Bottle) async -> Bool {
        // Deliberately does NOT go through runWineserverProcess: a -k0 probe
        // only needs WINEPREFIX, while the full path builds the entire launch
        // environment and creates + retention-scans a log file per call — the
        // sidebar repeats this probe every 60 seconds for every visible bottle.
        // WineProcessQuery.run gives the same lean spawn WITH a timeout, so a
        // wedged wineserver can't leak the continuation + process forever.
        let running: Bool
        do {
            running = try await probeWineserver(for: bottle)
        } catch {
            // Informational only (the sidebar repeats this every 60s): an
            // unresolvable engine or a wedged probe reads as "not running".
            // Engine selection never consults this — it uses the throwing
            // ``probeWineserver(for:)`` so an unknown state refuses.
            running = false
        }

        processLogger.debug(
            "Wineserver probe for '\(bottle.settings.name)': \(running ? "active" : "idle")"
        )
        return running
    }

    /// Lists the bottle's Windows processes through a Unicode Toolhelp snapshot.
    ///
    /// The bundled helper uses Process32FirstW/Process32NextW and writes UTF-8 explicitly.
    /// Bounded output capture keeps helper failures distinct from a successful empty observation.
    ///
    /// - Parameter bottle: The bottle whose processes to list.
    /// - Returns: The parsed process list.
    /// - Throws: A spawn, timeout, output-decoding or helper error.
    @MainActor
    static func listProcesses(for bottle: Bottle) async throws -> [WineProcess] {
        try await withEngineOperation(bottle: bottle) {
            let engine = try engine(for: bottle)
            var environment = try constructWineEnvironment(for: bottle, environment: [:], engine: engine)
            environment["WINEDEBUG"] = "-all"
            environment["LC_ALL"] = "en_US.UTF-8"
            let snapshotEnvironment = environment
            let executable = engine.wineBinary
            let key = WineProcessSnapshotPool.Key(executable: executable, environment: environment)
            let processes = try await WineProcessSnapshotPool.shared.processes(key: key) {
                try await queryProcesses(executable: executable, environment: snapshotEnvironment)
            }
            try Task.checkCancellation()
            return processes
        }
    }

    internal static var processSnapshotHelperURL: URL? {
        Bundle.module.url(forResource: "WhiskyProcessSnapshot", withExtension: "exe")
    }

    internal static func queryProcesses(executable: URL, environment: [String: String]) async throws -> [WineProcess] {
        guard let helper = processSnapshotHelperURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        let result = try await WineProcessQuery.run(
            executable: executable, arguments: [helper.path], environment: environment
        )
        guard result.exitCode == 0 else {
            throw WineProcessQuery.Failure.commandFailed(result.exitCode, String(result.diagnostics.prefix(2_048)))
        }
        let processes = parseTasklistOutput(result.output)
        guard !processes.isEmpty else { throw WineProcessQuery.Failure.invalidProcessList }
        return processes
    }

    /// Interprets a probe exit status: `0` means a server answered, `1` means
    /// none did. Any other status — a dyld crash, a bad loader, a signal — is
    /// an UNKNOWN state, not "idle": callers deciding whether mutation is
    /// safe must fail closed, so it throws with the captured diagnostics.
    internal static func interpretProbeExit(_ result: WineProcessQuery.Result) throws -> Bool {
        switch result.exitCode {
        case 0: return true
        case 1: return false
        default:
            throw WineProcessQuery.Failure.commandFailed(
                result.exitCode, String(result.diagnostics.prefix(2_048))
            )
        }
    }

    /// The low-level probe invocation, injectable so tests can drive
    /// 0/1/other/timeout outcomes without spawning a real `wineserver`.
    /// Task-local so parallel suites never share an injected probe.
    @TaskLocal internal static var probeWineserverRunner:
        @Sendable (URL, [String], [String: String], TimeInterval) async throws -> WineProcessQuery.Result =
        { executable, arguments, environment, timeout in
            try await WineProcessQuery.run(
                executable: executable, arguments: arguments,
                environment: environment, timeout: timeout
            )
        }

    /// Whole-probe override for cross-module tests that cannot reach the
    /// internal runner: the bound engine still resolves, only the spawn is
    /// replaced. Task-local like the other seams.
    @TaskLocal static var wineserverProbeOverride:
        (@Sendable (URL, URL) async throws -> Bool)?

    /// A failed executable query propagates separately from a stopped server.
    ///
    /// Exit code 0 means a server answers for the prefix; 1 means none does;
    /// anything else throws. A spawn failure, a timeout or an engine that
    /// will not resolve throws, so a caller deciding whether mutation is safe
    /// fails closed instead of mistaking an unknown state for idle. The probe
    /// runs under the selected engine's own server binary and library paths —
    /// a missing or unapproved selection is part of the answer.
    ///
    /// - Parameters:
    ///   - bottle: The bottle whose wineserver to probe.
    ///   - engine: The already-resolved engine to probe with. `nil` resolves
    ///     the bottle's bound engine through the active engine store.
    @MainActor
    static func probeWineserver(for bottle: Bottle, engine explicitEngine: WineEngine? = nil) async throws -> Bool {
        let engine = try explicitEngine ?? Self.engine(for: bottle)
        if let override = wineserverProbeOverride {
            return try await override(engine.wineserverBinary, bottle.url)
        }
        var environment = engine.probeEnvironment
        environment["WINEPREFIX"] = bottle.url.path(percentEncoded: false)
        let result = try await probeWineserverRunner(
            engine.wineserverBinary, ["-k0"], environment, 3
        )
        return try interpretProbeExit(result)
    }

    /// Whether ANY wineserver answers on this host — deliberately global.
    ///
    /// Used only by the missing-engine recovery path in engine selection,
    /// where the bottle's own server binary is gone: if anything Wine-ish
    /// still runs, recovery refuses rather than rebind a prefix a foreign
    /// server might still hold. Injectable so tests never spawn a probe.
    /// `pgrep` shares the probe contract: 0 running, 1 idle, anything else
    /// throws. Non-Maltoria Wine users hold no leases; the mutual exclusion
    /// is Maltoria-internal by design. Task-local for test injection.
    @TaskLocal static var anyWineserverRunning: @Sendable () async throws -> Bool = {
        let result = try await WineProcessQuery.run(
            executable: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: ["-xq", "wineserver"], environment: [:], timeout: 5
        )
        return try interpretProbeExit(result)
    }

    /// Parses the CSV shared by the Unicode snapshot helper and legacy tasklist output.
    ///
    /// The expected format is quoted CSV with a header line:
    /// ```
    /// "Image Name","PID","Session Name","Session#","Mem Usage"
    /// "game.exe","42","Console","0","24 K"
    /// ```
    ///
    /// Lines that cannot be parsed (wrong field count, non-numeric PID) are silently skipped.
    /// All returned processes have ``ProcessSource/untracked`` source; the caller should
    /// update the source after merging with ``ProcessRegistry`` data.
    ///
    /// - Parameter output: A complete UTF-8 process snapshot, with an optional header.
    /// - Returns: An array of parsed ``WineProcess`` instances.
    static func parseTasklistOutput(_ output: String) -> [WineProcess] {
        let lines = output.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
        var processes: [WineProcess] = []
        processes.reserveCapacity(lines.count)

        for line in lines {
            let fields = tasklistFields(String(line))

            // Require at least 5 fields: Image Name, PID, Session Name, Session#, Mem Usage
            guard fields.count >= 5 else { continue }

            // Skip the header line
            if fields[1] == "PID" {
                continue
            }

            // Parse the PID
            guard let pid = Int32(fields[1]) else { continue }

            let imageName = fields[0]
            let memoryUsage = fields[4]

            processes.append(WineProcess(
                imageName: imageName,
                winePID: pid,
                memoryUsage: memoryUsage,
                kind: ProcessKind.classify(imageName)
            ))
        }

        return processes
    }

    private static func tasklistFields(_ line: String) -> [String] {
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

    /// Sends a graceful kill request for a single Wine process via `taskkill.exe`.
    ///
    /// This asks the process to terminate cleanly. If the process has already
    /// exited, the error is silently ignored.
    ///
    /// - Parameters:
    ///   - winePID: The Wine/Windows PID to terminate.
    ///   - bottle: The bottle containing the process.
    @MainActor
    static func gracefulKillProcess(winePID: Int32, bottle: Bottle) async {
        do {
            try await Wine.runWine(
                ["taskkill.exe", "/PID", String(winePID)],
                bottle: bottle
            )
            processLogger.info("Sent graceful kill to Wine PID \(winePID)")
        } catch {
            processLogger.debug(
                "Graceful kill for Wine PID \(winePID) failed (process may have exited): \(error.localizedDescription)"
            )
        }
    }

    /// Sends a forced kill request for a single Wine process via `taskkill.exe /F`.
    ///
    /// This forcefully terminates the process without giving it a chance to
    /// clean up. If the process has already exited, the error is silently ignored.
    ///
    /// - Parameters:
    ///   - winePID: The Wine/Windows PID to terminate.
    ///   - bottle: The bottle containing the process.
    @MainActor
    static func forceKillProcess(winePID: Int32, bottle: Bottle) async {
        do {
            try await Wine.runWine(
                ["taskkill.exe", "/PID", String(winePID), "/F"],
                bottle: bottle
            )
            processLogger.info("Sent force kill to Wine PID \(winePID)")
        } catch {
            processLogger.debug(
                "Force kill for Wine PID \(winePID) failed (process may have exited): \(error.localizedDescription)"
            )
        }
    }
}
