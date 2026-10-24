//
//  WinetricksService+Install.swift
//  Whisky
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

import Darwin
import Foundation
import os

private let logger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "WinetricksInstall")

/// Progress events emitted during a headless winetricks verb installation.
public enum WinetricksInstallProgress: Sendable {
    /// The installation is being prepared (environment setup).
    case preparing
    /// A line of output from the winetricks process.
    case output(String)
    /// The installation completed with the given exit code.
    case completed(exitCode: Int32)
    /// The installation failed with an error message.
    case failed(String)
}

// MARK: - Headless Verb Installation

public extension WinetricksService {
    /// Installs a single winetricks verb headlessly via Process.
    ///
    /// Runs the verb installation as a child process (not via Terminal AppleScript),
    /// streaming stdout and stderr lines as ``WinetricksInstallProgress/output(_:)``
    /// events. This keeps volume access attributed to Whisky rather than Terminal.
    ///
    /// After successful completion, the ``WinetricksVerbCache`` is refreshed
    /// by calling ``loadInstalledVerbs(for:)``.
    ///
    /// - Parameters:
    ///   - verb: The winetricks verb name to install (e.g. "vcrun2019").
    ///   - bottle: The bottle whose prefix to install into.
    ///   - timeout: Maximum time in seconds before the process is terminated.
    ///     Defaults to 600 seconds (10 minutes).
    /// - Returns: An ``AsyncStream`` of progress events.
    static func installVerb(
        _ verb: String,
        for bottle: Bottle,
        timeout: TimeInterval = 600
    ) -> AsyncStream<WinetricksInstallProgress> {
        AsyncStream(bufferingPolicy: .bufferingNewest(512)) { continuation in
            let task = Task {
                await executeVerbInstall(verb, for: bottle, timeout: timeout, continuation: continuation)
            }
            // A consumer that stops iterating (the install sheet's Cancel)
            // cancels the install rather than leaving it running headless.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Installs multiple winetricks verbs sequentially with per-verb progress.
    ///
    /// Verbs are installed one at a time in the order given. A failure in
    /// one verb does not prevent subsequent verbs from being attempted.
    ///
    /// - Parameters:
    ///   - verbs: The winetricks verb names to install.
    ///   - bottle: The bottle whose prefix to install into.
    /// - Returns: An ``AsyncStream`` of tuples pairing the current verb
    ///   name with its progress event.
    static func installVerbs(
        _ verbs: [String],
        for bottle: Bottle
    ) -> AsyncStream<(verb: String, progress: WinetricksInstallProgress)> {
        AsyncStream(bufferingPolicy: .bufferingNewest(512)) { continuation in
            let task = Task {
                for verb in verbs where !Task.isCancelled {
                    for await progress in installVerb(verb, for: bottle) {
                        continuation.yield((verb: verb, progress: progress))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Private Helpers

    /// Configures and returns a Process for running a winetricks verb.
    ///
    /// The vcrun verbs are passed `--force`: Microsoft rotates the vc_redist
    /// binaries in place, so the checksums pinned in the bundled winetricks go
    /// stale between releases and the unattended install aborts with exit 1 on
    /// the SHA256 mismatch (winetricks#2195).
    ///
    /// They also get `-q` (W_OPT_UNATTENDED, adds `/q` to the redist install):
    /// without it the vc_redist installer shows its wizard and waits for a
    /// click nothing in the panel prompts for, so the process never exits and
    /// the winetricks.log entry is never written. Scoped to the vcrun verbs
    /// until other verbs are checked for unattended behavior.
    private static func configureInstallProcess(
        verb: String,
        bottleURL: URL,
        resourcesURL: URL
    ) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let winetricksPath = resourcesURL.appending(path: "winetricks").path(percentEncoded: false)
        var arguments = ["bash", winetricksPath]
        if verb.hasPrefix("vcrun") {
            arguments.append("--force")
            arguments.append("-q")
        }
        arguments.append(verb)
        process.arguments = arguments
        process.environment = [
            "WINEPREFIX": bottleURL.path(percentEncoded: false),
            "WINE": "wine64",
            "PATH": [
                WhiskyWineInstaller.binFolder.path(percentEncoded: false),
                resourcesURL.path(percentEncoded: false),
                "/usr/bin",
                "/bin"
            ].joined(separator: ":"),
            "HOME": NSHomeDirectory()
        ]
        return process
    }

    /// Attaches readability handlers that forward pipe output as progress events.
    private static func attachOutputHandlers(
        stdout: Pipe,
        stderr: Pipe,
        continuation: AsyncStream<WinetricksInstallProgress>.Continuation
    ) {
        for pipe in [stdout, stderr] {
            let decoder = WinetricksOutputDecoder()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                for line in decoder.append(data, finish: data.isEmpty) {
                    continuation.yield(.output(line))
                }
                if data.isEmpty {
                    handle.readabilityHandler = nil
                }
            }
        }
    }

    /// Executes the verb installation process with timeout and cache refresh.
    private static func executeVerbInstall(
        _ verb: String,
        for bottle: Bottle,
        timeout: TimeInterval,
        continuation: AsyncStream<WinetricksInstallProgress>.Continuation
    ) async {
        guard !NetworkSettings.isOffline else {
            continuation.yield(.failed(String(localized: "settings.offline.networkRequired")))
            continuation.finish()
            return
        }
        continuation.yield(.preparing)

        let bottleURL = await MainActor.run { bottle.url }

        guard let resourcesURL = WhiskyResources.tool("cabextract")?.deletingLastPathComponent()
        else {
            logger.warning("Could not locate cabextract resource for winetricks install")
            continuation.yield(.failed("Missing cabextract resource"))
            continuation.finish()
            return
        }

        let process = configureInstallProcess(verb: verb, bottleURL: bottleURL, resourcesURL: resourcesURL)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        attachOutputHandlers(stdout: stdoutPipe, stderr: stderrPipe, continuation: continuation)

        do {
            try process.run()
            logger.info("Started winetricks install for verb '\(verb)'")
        } catch {
            logger.error("Failed to launch winetricks install: \(error.localizedDescription)")
            continuation.yield(.failed(error.localizedDescription))
            continuation.finish()
            return
        }

        let interrupted = await awaitProcessCompletion(process, timeout: timeout)
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        if let interrupted {
            continuation.yield(.failed(interrupted))
            continuation.finish()
            return
        }
        let exitCode = process.terminationStatus
        logger.info("winetricks install '\(verb)' exited with status \(exitCode)")
        continuation.yield(.completed(exitCode: exitCode))

        // Refresh the verb cache after installation
        _ = await WinetricksService.loadInstalledVerbs(for: bottle)
        continuation.finish()
    }

    /// Polling keeps the cooperative executor available and bounds termination after cancellation.
    internal static func awaitProcessCompletion(_ process: Process, timeout: TimeInterval) async -> String? {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        var interruption: String?
        var killDeadline: Date?
        while process.isRunning {
            if interruption == nil, Task.isCancelled || Date() >= deadline {
                interruption = Task.isCancelled ? "Installation cancelled" : "Installation timed out"
                process.terminate()
                killDeadline = Date().addingTimeInterval(1)
            }
            if let killDeadline, Date() >= killDeadline, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            // The detached timer also yields after cancellation of the parent task.
            await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
        }
        return interruption
    }
}

/// Per-pipe incremental UTF-8 decoding preserves split scalars and bounds pending output.
final class WinetricksOutputDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    func append(_ data: Data, finish: Bool = false) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        while let end = pending.firstIndex(of: 10) {
            lines.append(Self.lossyString(pending[..<end]))
            pending.removeSubrange(...end)
        }
        if pending.count > 8_192 {
            var end = pending.count
            for suffix in 0 ... 3 {
                let count = pending.count - suffix
                if String(data: pending.prefix(count), encoding: .utf8) != nil {
                    end = count
                    break
                }
            }
            lines.append(Self.lossyString(pending.prefix(end)))
            pending.removeFirst(end)
        }
        if finish, !pending.isEmpty {
            lines.append(Self.lossyString(pending))
            pending.removeAll(keepingCapacity: true)
        }
        return lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Lossy decoding is intentional: a split multibyte scalar must not drop a line.
    private static func lossyString(_ bytes: some Collection<UInt8>) -> String {
        /* Lossy decoding is intentional. */ // swiftlint:disable:next optional_data_string_conversion
        String(decoding: bytes, as: UTF8.self)
    }
}
