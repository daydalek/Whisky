//
//  SteamClientReadinessTests.swift
//  WhiskyKitTests
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
import Testing
@testable import WhiskyKit

@Suite("Steam readiness evidence")
struct SteamClientReadinessTests {
    private let bootstrap = "[2026-10-16 15:00:00] Startup - Steam Client launched with: steam.exe"
    private let initialized = "[2026-10-16 15:00:10] STARTUP SlowJSMethodCall UI.NotifyAppInitialized took 1ms"
    private let login = "[2026-10-16 15:00:09] [Logged On, 4, 7] Logon response processing complete"

    @Test func requiresBothLoginAndInitializedUI() {
        #expect(SteamClientReadiness.parse(bootstrap: bootstrap, connection: login, console: "").state == .initializing)
        #expect(SteamClientReadiness.parse(bootstrap: bootstrap, connection: "", console: initialized)
            .state == .waitingForLogin)
        #expect(SteamClientReadiness.parse(bootstrap: bootstrap, connection: login, console: initialized)
            .state == .ready)
    }

    @Test func oldSessionEvidenceIsNotReady() {
        let fresh = "[2026-10-16 16:00:00] Startup - Steam Client launched with: steam.exe"
        #expect(!SteamClientReadiness.parse(
            bootstrap: bootstrap + "\n" + fresh,
            connection: login,
            console: initialized
        ).state.canLaunch)
        #expect(!SteamClientReadiness.parse(bootstrap: "", connection: login, console: initialized).state.canLaunch)
    }

    @Test func disconnectInvalidatesOnlineReadiness() {
        let connection = login + "\n[2026-10-16 15:01:00] [Logged Off, 0, 0] Disconnected"
        #expect(SteamClientReadiness.parse(
            bootstrap: bootstrap,
            connection: connection,
            console: initialized
        ).state == .waitingForLogin)
    }

    @Test func explicitOfflineModeDoesNotRequireOnlineLogin() {
        let offline = initialized + "\n[2026-10-16 15:02:00] Entering offline mode"
        #expect(SteamClientReadiness.parse(bootstrap: bootstrap, connection: "", console: offline)
            .state == .offlineReady)
        let reconnect = "[2026-10-16 15:03:00] [Connecting, 4, 0] Connecting"
        #expect(!SteamClientReadiness.parse(bootstrap: bootstrap, connection: reconnect, console: offline).state
            .canLaunch)
    }

    @Test func historicalGameActionsAreNotReceipts() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("logs/console_log.txt")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("GameAction [AppID 1, ActionID 1] : Completed\n".utf8).write(to: log)
        let receipt = SteamLaunchReceipt(steamRoot: root)
        #expect(!receipt.wasAccepted(appID: 1))
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("GameAction [AppID 1, ActionID 2] : SynchronizingCloud\n".utf8))
        try handle.close()
        #expect(receipt.wasAccepted(appID: 1))
        #expect(!receipt.wasAccepted(appID: 2))
    }

    @Test @MainActor func coldWaitRejectsUnchangedSession() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data(bootstrap.utf8).write(to: logs.appendingPathComponent("bootstrap_log.txt"))
        try Data(login.utf8).write(to: logs.appendingPathComponent("connection_log.txt"))
        try Data(initialized.utf8).write(to: logs.appendingPathComponent("console_log.txt"))
        await #expect(throws: SteamOrchestratorError.clientNotReady) {
            try await SteamClientReadiness.wait(
                steamRoot: root,
                previousSession: "2026-10-16 15:00:00",
                requiresNewSession: true,
                timeout: 0,
                pollInterval: .milliseconds(1)
            )
        }
    }

    @Test func unreadableOrRotatedReceiptDisablesAutomaticRetry() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = SteamLaunchReceipt(steamRoot: root)
        #expect(missing.status(appID: 1) == .unavailable)
        let log = root.appendingPathComponent("logs/console_log.txt")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Previous log content".utf8).write(to: log)
        let receipt = SteamLaunchReceipt(steamRoot: root)
        try FileManager.default.moveItem(at: log, to: log.appendingPathExtension("old"))
        try Data("New log".utf8).write(to: log)
        #expect(receipt.status(appID: 1) == .unavailable)
    }
}
