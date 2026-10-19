//
//  SteamClientReadiness.swift
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

/// Conservative, bottle-local readiness evidence. A steam.exe process alone is
/// insufficient. Log timestamps are compared with each other, not the host's
/// clock (Wine and macOS may use different time zones).
public enum SteamClientReadiness {
    public enum State: Sendable, Equatable {
        case initializing, waitingForLogin, ready, offlineReady
        public var canLaunch: Bool {
            self == .ready || self == .offlineReady
        }
    }

    public struct Snapshot: Sendable {
        public let session: String?
        public let state: State
    }

    public static func snapshot(steamRoot: URL) -> Snapshot {
        let logs = steamRoot.appendingPathComponent("logs")
        return parse(
            bootstrap: tail(logs.appendingPathComponent("bootstrap_log.txt")),
            connection: tail(logs.appendingPathComponent("connection_log.txt")),
            console: tail(logs.appendingPathComponent("console_log.txt"))
        )
    }

    static func parse(bootstrap: String, connection: String, console: String) -> Snapshot {
        let session = bootstrap.split(whereSeparator: \.isNewline).last {
            $0.contains("Startup - Steam Client launched with:")
        }.flatMap(timestamp)
        guard let session else { return Snapshot(session: nil, state: .initializing) }
        func current(_ text: String) -> [Substring] {
            text.split(whereSeparator: \.isNewline).filter {
                guard let date = timestamp($0) else { return false }
                return date >= session
            }
        }
        let consoleLines = current(console)
        let uiReady = consoleLines.contains { $0.contains("UI.NotifyAppInitialized") }
        var loggedOn = false
        var lastOnlineAttempt = ""
        for line in current(connection) {
            if line.contains("[Logged On,") {
                loggedOn = true
            }
            if line.contains("[Logged Off,") || line.contains("[Logging On,")
                || line.contains("[Connecting,") {
                loggedOn = false
            }
            if line.contains("[Logging On,") || line.contains("[Connecting,") {
                lastOnlineAttempt = timestamp(line) ?? lastOnlineAttempt
            }
        }
        if uiReady, loggedOn {
            return Snapshot(session: session, state: .ready)
        }
        // Only explicit offline-mode evidence counts, never a generic network
        // failure or a cached account. The UI must also have initialized.
        let offlineDate = consoleLines.last(where: {
            $0.localizedCaseInsensitiveContains("running in offline mode")
                || $0.localizedCaseInsensitiveContains("entering offline mode")
        }).flatMap(timestamp)
        if uiReady, let offlineDate, offlineDate >= lastOnlineAttempt {
            return Snapshot(session: session, state: .offlineReady)
        }
        return Snapshot(session: session, state: uiReady ? .waitingForLogin : .initializing)
    }

    @MainActor
    public static func wait(
        steamRoot: URL, previousSession: String? = nil, requiresNewSession: Bool = false,
        timeout: TimeInterval = 180, pollInterval: Duration = .seconds(2),
        onState: (State) -> Void = { _ in }, showClient: () -> Void = {}
    ) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start.advanced(by: .seconds(timeout))
        var shown = false
        repeat {
            try Task.checkCancellation()
            let snapshot = await Task.detached { Self.snapshot(steamRoot: steamRoot) }.value
            try Task.checkCancellation()
            let current = !requiresNewSession || (snapshot.session != nil && snapshot.session != previousSession)
            let state: State = current ? snapshot.state : .initializing
            onState(state)
            if state.canLaunch {
                return
            }
            if !shown, start.duration(to: clock.now) >= .seconds(10) {
                shown = true
                showClient()
            }
            if clock.now >= deadline {
                break
            }
            try await Task.sleep(for: pollInterval)
        } while true
        throw SteamOrchestratorError.clientNotReady
    }

    private static func timestamp(_ line: Substring) -> String? {
        guard line.first == "[", line.count >= 21 else { return nil }
        let date = String(line.dropFirst().prefix(19))
        guard date.count == 19, date.contains("-"), date.contains(":") else { return nil }
        return date
    }

    static func tail(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            try handle.seek(toOffset: end > 524_288 ? end - 524_288 : 0)
            guard let data = try handle.readToEnd() else { return "" }
            // A log-tail boundary can split a code point; retain the remaining lines.
            // swiftlint:disable:next optional_data_string_conversion
            return String(decoding: data, as: UTF8.self)
        } catch { return "" }
    }
}

/// Shared GUI/CLI confirmation and conservative one-retry policy.
public enum SteamGameLaunchMonitor {
    private enum Event: Sendable {
        case poll
        case requestFinished(Result<Wine.ProgramRunResult, any Error>)

        func isPoll() throws -> Bool {
            guard case let .requestFinished(result) = self else { return true }
            let runResult = try result.get()
            if runResult.exitCode != 0 {
                throw SteamOrchestratorError.launchRequestFailed(code: runResult.exitCode)
            }
            return false
        }
    }

    @MainActor
    private final class EventSource {
        let stream: AsyncStream<Event>
        private let continuation: AsyncStream<Event>.Continuation
        private let polling: Task<Void, Never>
        private var observers: [Task<Void, Never>] = []

        init(deadline: ContinuousClock.Instant, pollInterval: Duration) {
            let (stream, continuation) = AsyncStream<Event>.makeStream()
            self.stream = stream
            self.continuation = continuation
            polling = Task {
                repeat {
                    continuation.yield(.poll)
                    let remaining = ContinuousClock.now.duration(to: deadline)
                    guard remaining > .zero else { return }
                    do {
                        try await Task.sleep(for: min(max(pollInterval, .milliseconds(1)), remaining))
                    } catch { return }
                } while !Task.isCancelled
            }
        }

        func observe(_ task: Task<Wine.ProgramRunResult, any Error>?) {
            guard let task else { return }
            let continuation = continuation
            // Observers wait independently; stopping confirmation releases its
            // event stream immediately while the Steam request can keep running.
            observers.append(Task { _ = await continuation.yield(.requestFinished(task.result)) })
        }

        func stop() {
            polling.cancel()
            observers.forEach { $0.cancel() }
            continuation.finish()
        }
    }

    @MainActor
    public static func wait(
        names: Set<String>, timeout: TimeInterval = 120, retryDelay: TimeInterval = 10,
        pollInterval: Duration = .seconds(2),
        runningImages: () async -> Set<String>, accepted: () -> Bool,
        prepareRetry: () async throws -> Void, retry: () async throws -> Void,
        launchTask: Task<Wine.ProgramRunResult, any Error>? = nil,
        retryLaunch: (() async throws -> Task<Wine.ProgramRunResult, any Error>?)? = nil
    ) async throws -> Bool {
        try Task.checkCancellation()
        guard !names.isEmpty else { return false }
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start.advanced(by: .seconds(timeout))
        var retried = false
        var received = false
        let events = EventSource(deadline: deadline, pollInterval: pollInterval)
        events.observe(launchTask)
        defer { events.stop() }

        for await event in events.stream {
            try Task.checkCancellation()
            guard try event.isPoll() else { continue }
            let running = await runningImages()
            try Task.checkCancellation()
            if !running.isDisjoint(with: names) {
                return true
            }
            received = received || accepted()
            if clock.now >= deadline {
                return false
            }
            if !retried, !received, start.duration(to: clock.now) >= .seconds(retryDelay) {
                retried = true
                try await prepareRetry()
                try Task.checkCancellation()
                let afterWait = await runningImages()
                try Task.checkCancellation()
                if !afterWait.isDisjoint(with: names) {
                    return true
                }
                if clock.now >= deadline {
                    return false
                }
                if !accepted() {
                    if let retryLaunch {
                        try await events.observe(retryLaunch())
                    } else {
                        try await retry()
                    }
                }
            }
        }
        try Task.checkCancellation()
        return false
    }
}
