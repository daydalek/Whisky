//
//  SteamDownloadMonitor.swift
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

import Foundation
import os
import WhiskyKit

private let logger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "SteamDownloadMonitor")

/// Status of a Steam download stall check.
enum StallStatus: Equatable {
    case noDownloads
    case downloading
    case likelyStalled(duration: TimeInterval)
    case confirmedStall(duration: TimeInterval, evidence: [String])
}

/// Monitors Steam download directories for stall detection.
///
/// Polls `steamapps/downloading/` subdirectories on a configurable interval,
/// comparing file sizes and modification times across samples. When no progress
/// is detected for the configured threshold (default 3 minutes), posts a
/// notification for the UI layer. Stall notifications are rate-limited to
/// once per bottle per session.
@MainActor
class SteamDownloadMonitor: ObservableObject {
    @Published var status: StallStatus = .noDownloads
    @Published var isMonitoring: Bool = false

    private let stallThreshold: TimeInterval = 180
    private let samplingInterval: TimeInterval = 45
    private var lastSnapshot: SteamDownloadSnapshot?
    private var stallStartTime: Date?
    private var alertedThisSession: Set<String> = []
    private var monitoringTask: Task<Void, Never>?

    // MARK: - Lifecycle

    /// Starts monitoring if the detected launcher is Steam.
    func startMonitoring(bottleURL: URL, detectedLauncher: LauncherType?) {
        guard detectedLauncher == .steam, !isMonitoring else { return }

        isMonitoring = true
        lastSnapshot = nil
        stallStartTime = nil
        status = .noDownloads
        logger.info("Starting Steam download monitoring for bottle")

        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(45 * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self?.sample(bottleURL: bottleURL)
            }
        }
    }

    /// Stops the monitoring loop and resets state.
    func stopMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
        isMonitoring = false
        lastSnapshot = nil
        stallStartTime = nil
        status = .noDownloads
    }

    /// Marks a bottle as "don't warn again" for this session.
    func suppressWarnings(for bottleURL: URL) {
        alertedThisSession.insert(bottleURL.path(percentEncoded: false))
    }

    // MARK: - Sampling

    /// Samples the Steam download directory and updates stall status across all library roots.
    private func sample(bottleURL: URL) async {
        let roots = SteamLibrary.libraryRoots(bottleURL: bottleURL)
        let scan = Task.detached(priority: .utility) {
            try SteamDownloadSnapshot.capture(libraryRoots: roots)
        }
        let currentSnapshot: SteamDownloadSnapshot
        do {
            currentSnapshot = try await withTaskCancellationHandler {
                try await scan.value
            } onCancel: {
                scan.cancel()
            }
        } catch {
            guard !Task.isCancelled else { return }
            stallStartTime = nil
            logger.debug("Steam download sampling deferred: \(error.localizedDescription)")
            return
        }
        guard !Task.isCancelled else { return }

        if currentSnapshot.isEmpty {
            status = .noDownloads
            stallStartTime = nil
            lastSnapshot = nil
            return
        }

        let hasProgress = lastSnapshot.map { currentSnapshot != $0 } ?? true
        lastSnapshot = currentSnapshot

        if hasProgress {
            status = .downloading
            stallStartTime = nil
        } else {
            if stallStartTime == nil {
                stallStartTime = Date()
            }
            let stallDuration = Date().timeIntervalSince(stallStartTime ?? Date())

            if stallDuration >= stallThreshold {
                let evidence = await checkLogEvidence()
                status = evidence.isEmpty
                    ? .likelyStalled(duration: stallDuration)
                    : .confirmedStall(duration: stallDuration, evidence: evidence)
                postStallNotificationIfNeeded(
                    bottleURL: bottleURL, duration: stallDuration, evidence: evidence
                )
            } else {
                status = .downloading
            }
        }
    }

    // MARK: - Log Evidence

    /// Checks Wine logs for network timeout patterns to corroborate a stall.
    private nonisolated func checkLogEvidence() async -> [String] {
        var evidence: [String] = []
        let logsFolder = Wine.logsFolder

        guard let logFiles = try? FileManager.default.contentsOfDirectory(
            at: logsFolder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        else { return evidence }

        let recentLogs = logFiles
            .filter { $0.pathExtension == "log" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return (lhsDate ?? .distantPast) > (rhsDate ?? .distantPast)
            }
            .prefix(3)

        let patterns = [
            "winhttp.*timeout", "wininet.*timeout", "WinHTTP.*timed out",
            "HTTP.*connection reset", "Steam.*download.*failed"
        ]

        for logFile in recentLogs {
            guard let content = try? String(contentsOf: logFile, encoding: .utf8) else { continue }
            let tail = content.suffix(8_000)
            for pattern in patterns {
                if let regex = try? Regex(pattern), tail.contains(regex) {
                    evidence.append("Log evidence: \(pattern) in \(logFile.lastPathComponent)")
                }
            }
        }
        return evidence
    }

    // MARK: - Notification

    /// Posts a stall notification, rate-limited to once per bottle per session.
    private func postStallNotificationIfNeeded(
        bottleURL: URL, duration: TimeInterval, evidence: [String]
    ) {
        let bottleKey = bottleURL.path(percentEncoded: false)
        guard !alertedThisSession.contains(bottleKey) else { return }
        alertedThisSession.insert(bottleKey)

        let stallMinutes = Int(duration / 60)
        logger.warning("Steam download stall detected: \(stallMinutes)min, evidence: \(evidence.count)")

        NotificationCenter.default.post(
            name: .steamDownloadStallDetected,
            object: nil,
            userInfo: [
                "bottleURL": bottleURL, "duration": duration,
                "evidence": evidence, "stallMinutes": stallMinutes
            ]
        )
    }
}

// MARK: - Notification Name

extension Notification.Name {
    /// Posted when a Steam download stall is detected.
    static let steamDownloadStallDetected = Notification.Name(
        "com.franke.Whisky.steamDownloadStallDetected"
    )
}
