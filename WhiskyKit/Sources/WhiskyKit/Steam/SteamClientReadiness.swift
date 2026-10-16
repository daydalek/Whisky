// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Conservative, bottle-local readiness evidence. A steam.exe process alone is
/// insufficient. Log timestamps are compared with each other, not the host's
/// clock (Wine and macOS may use different time zones).
public enum SteamClientReadiness {
    public enum State: Sendable, Equatable {
        case initializing, waitingForLogin, ready, offlineReady
        public var canLaunch: Bool { self == .ready || self == .offlineReady }
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
            if line.contains("[Logged On,") { loggedOn = true }
            if line.contains("[Logged Off,") || line.contains("[Logging On,")
                || line.contains("[Connecting,") { loggedOn = false }
            if line.contains("[Logging On,") || line.contains("[Connecting,") {
                lastOnlineAttempt = timestamp(line) ?? lastOnlineAttempt
            }
        }
        if uiReady && loggedOn { return Snapshot(session: session, state: .ready) }
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
            if state.canLaunch { return }
            if !shown && start.duration(to: clock.now) >= .seconds(10) {
                shown = true
                showClient()
            }
            if clock.now >= deadline { break }
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

    private static func tail(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            try handle.seek(toOffset: end > 524_288 ? end - 524_288 : 0)
            return String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        } catch { return "" }
    }
}

/// New bytes only: an old GameAction must not suppress a retry or masquerade as
/// this launch's success. Missing/rotated logs suppress automatic retries.
public struct SteamLaunchReceipt: Sendable {
    public enum Status: Sendable, Equatable { case waiting, accepted, unavailable }
    private let url: URL
    private let offset: UInt64
    private let inode: UInt64?

    public init(steamRoot: URL) {
        url = steamRoot.appendingPathComponent("logs/console_log.txt")
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        offset = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    public func wasAccepted(appID: Int) -> Bool {
        status(appID: appID) == .accepted
    }

    public func status(appID: Int) -> Status {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unavailable }
        defer { try? handle.close() }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let currentInode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            let end = try handle.seekToEnd()
            // If continuity is lost, automatic retries are unsafe: the request
            // may already have been handled in the rotated/unavailable log.
            guard inode != nil, currentInode == inode, end >= offset else { return .unavailable }
            let beginning = offset
            try handle.seek(toOffset: max(beginning, end > 524_288 ? end - 524_288 : 0))
            let text = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
            let accepted = text.contains("GameAction [AppID \(appID),")
                || text.contains("Game process added : AppID \(appID) ")
            return accepted ? .accepted : .waiting
        } catch { return .unavailable }
    }
}

/// Shared GUI/CLI confirmation and conservative one-retry policy.
public enum SteamGameLaunchMonitor {
    @MainActor
    public static func wait(
        names: Set<String>, timeout: TimeInterval = 120, retryDelay: TimeInterval = 10,
        pollInterval: Duration = .seconds(2),
        runningImages: () async -> Set<String>, accepted: () -> Bool,
        prepareRetry: () async throws -> Void, retry: () async throws -> Void
    ) async throws -> Bool {
        try Task.checkCancellation()
        guard !names.isEmpty else { return false }
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start.advanced(by: .seconds(timeout))
        var retried = false
        var received = false
        repeat {
            try Task.checkCancellation()
            let running = await runningImages()
            try Task.checkCancellation()
            if !running.isDisjoint(with: names) { return true }
            received = received || accepted()
            if clock.now >= deadline { return false }
            if !retried && !received && start.duration(to: clock.now) >= .seconds(retryDelay) {
                retried = true
                try await prepareRetry()
                try Task.checkCancellation()
                let afterWait = await runningImages()
                try Task.checkCancellation()
                if !afterWait.isDisjoint(with: names) { return true }
                if clock.now >= deadline { return false }
                if !accepted() { try await retry() }
            }
            try await Task.sleep(for: pollInterval)
        } while true
    }
}
