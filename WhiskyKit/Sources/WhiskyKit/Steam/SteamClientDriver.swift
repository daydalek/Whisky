//
//  SteamClientDriver.swift
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

/// Everything ``SteamClientOrchestrator`` needs from the outside world: process
/// lists, starting the client, launching and killing games, and two lifecycle
/// hooks. The orchestrator owns the sequencing (single-flight client startup,
/// per-game phases, the shared process snapshot); the driver owns the side
/// effects, so tests can script one without Wine.
@MainActor
public protocol SteamClientDriver: AnyObject {
    /// Lower-cased `.exe` names of Wine processes visible to the host.
    ///
    /// Diagnostic host information; launch confirmation uses the bottle's Windows process list.
    func hostWineImageNames() async -> Set<String>

    /// The bottle's process list, as `tasklist.exe` reports it.
    func processList() async -> [WineProcess]

    /// Starts the Steam client silently. Must return promptly: the client runs
    /// for the whole session and the orchestrator watches for it separately.
    func startClient(steamExe: URL)
    /// Cancels preparation while preserving a client already handed off to Wine.
    func cancelClientStartup()

    /// Applies Steam's launcher fixes to the bottle. Only called when
    /// ``SteamClientOrchestrator/shouldApplyLauncherFixes(settings:)`` says so.
    func applyLauncherFixes()

    /// Hands `-applaunch` for the game to the running client.
    @discardableResult
    func launchGame(_ game: SteamGame) throws -> Task<Wine.ProgramRunResult, any Error>?

    /// Asks one of the bottle's processes to close.
    func killProcess(winePID: Int32) async

    /// The client is up (started here or found already running).
    func clientDidBecomeReady()

    /// The orchestrator is being stopped; release anything started in
    /// ``clientDidBecomeReady()``.
    func shutdown()

    /// Implementations must distinguish a client process from usable client IPC.
    func waitUntilReady(onState: @escaping @MainActor (SteamClientReadiness.State) -> Void) async throws
    func launchWasAccepted(_ game: SteamGame) -> Bool
    func waitForClientProcess(timeout: TimeInterval, pollInterval: Duration) async -> Bool
}

public extension SteamClientDriver {
    func cancelClientStartup() {}

    @discardableResult
    func launchGame(_ game: SteamGame) throws -> Task<Wine.ProgramRunResult, any Error>? {
        nil
    }

    /// Non-Wine drivers (including test doubles) may have an intrinsically ready
    /// client. The production Wine driver always implements the log/session gate.
    func waitUntilReady(onState: @escaping @MainActor (SteamClientReadiness.State) -> Void) async throws {
        try Task.checkCancellation()
    }

    func launchWasAccepted(_ game: SteamGame) -> Bool {
        true
    }

    func waitForClientProcess(timeout: TimeInterval, pollInterval: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        repeat {
            guard !Task.isCancelled else { return false }
            if await processList().contains(where: { $0.imageName.lowercased() == "steam.exe" }) {
                return !Task.isCancelled
            }
            if clock.now >= deadline {
                return false
            }
            do { try await Task.sleep(for: pollInterval) } catch { return false }
        } while true
    }
}

/// The production driver: Wine, `tasklist.exe`, `ps`, and ``SteamLauncher``.
///
/// `open` so the app can layer session-scoped behavior on the two lifecycle
/// hooks (download monitoring) without the kit knowing about it.
@MainActor
open class WineSteamClientDriver: SteamClientDriver {
    typealias ClientStarter = @MainActor (URL, Bottle, @escaping @MainActor () -> Void) -> Task<Void, Never>

    public let bottle: Bottle
    private let clientStarter: ClientStarter
    private let clientStartup = SteamClientStartup()
    private var previousSession: String?
    private var startedClient = false
    private var receipts: [Int: SteamLaunchReceipt] = [:]

    public init(bottle: Bottle) {
        self.bottle = bottle
        clientStarter = { SteamLauncher.startClient(steamExe: $0, bottle: $1, onHandoff: $2) }
    }

    init(bottle: Bottle, clientStarter: @escaping ClientStarter) {
        self.bottle = bottle
        self.clientStarter = clientStarter
    }

    /// Reads `ps` rather than spawning `tasklist.exe`, which is a whole Wine
    /// process: polled every couple of seconds, the wait for a cold Steam
    /// client spent dozens of them competing with the client it was waiting
    /// for. Wine's processes carry their Windows image name in the host
    /// process list, so this answers "nothing is running yet" for free.
    open func hostWineImageNames() async -> Set<String> {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: "/bin/ps")
            process.arguments = ["-Ao", "comm="]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let output = String(bytes: data, encoding: .utf8) else { return [] }
            return Self.exeImageNames(inProcessListing: output)
        }.value
    }

    /// The lower-cased `.exe` names in a `ps -Ao comm=` listing.
    ///
    /// Wine's processes show their Windows image path as the command, often
    /// with backslashes, so the last backslash-separated component is the
    /// image name. Anything that is not a `.exe` is host noise and dropped.
    public nonisolated static func exeImageNames(inProcessListing output: String) -> Set<String> {
        Set(
            output
                .split(whereSeparator: \.isNewline)
                .compactMap { line in
                    let name = (line.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last ?? line)
                        .lowercased()
                    return name.hasSuffix(".exe") ? String(name) : nil
                }
        )
    }

    open func processList() async -> [WineProcess] {
        guard await (try? Wine.probeWineserver(for: bottle)) == true else { return [] }
        return await (try? Wine.listProcesses(for: bottle)) ?? []
    }

    /// `steam.exe -silent` runs for the whole session, so the run is never awaited.
    open func startClient(steamExe: URL) {
        previousSession = SteamClientReadiness.snapshot(steamRoot: steamExe.deletingLastPathComponent()).session
        startedClient = true
        clientStartup.start { onHandoff in clientStarter(steamExe, bottle, onHandoff) }
    }

    open func cancelClientStartup() {
        clientStartup.cancel()
    }

    open func waitUntilReady(
        onState: @escaping @MainActor (SteamClientReadiness.State) -> Void
    ) async throws {
        guard let root = SteamLibrary.detectInstall(bottleURL: bottle.url) else {
            throw SteamOrchestratorError.steamNotInstalled
        }
        defer { startedClient = false }
        try await SteamClientReadiness.wait(
            steamRoot: root, previousSession: previousSession, requiresNewSession: startedClient,
            onState: onState, showClient: { SteamLauncher.showClient(steamRoot: root, bottle: self.bottle) }
        )
    }

    open func launchWasAccepted(_ game: SteamGame) -> Bool {
        // Unknown evidence must suppress retries too, not risk duplicate games.
        receipts[game.appId]?.status(appID: game.appId) != .waiting
    }

    /// Confirms the Windows Steam process and the bottle's new log session.
    /// Process queries are bounded and gated by server activity.
    open func waitForClientProcess(timeout: TimeInterval, pollInterval: Duration) async -> Bool {
        guard let root = SteamLibrary.detectInstall(bottleURL: bottle.url) else { return false }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        repeat {
            guard !Task.isCancelled else { return false }
            let session = SteamClientReadiness.snapshot(steamRoot: root).session
            // The new bootstrap marker means preparation has handed Steam to Wine.
            // Keep Windows snapshots out of the cold registry-import phase.
            if session != nil, !startedClient || session != previousSession {
                let names = await Set(processList().map { $0.imageName.lowercased() })
                if names.contains("steam.exe") {
                    return true
                }
            }
            if clock.now >= deadline {
                return false
            }
            do { try await Task.sleep(for: pollInterval) } catch { return false }
        } while true
    }

    /// Through the shared path, which carries the locale, DXVK and
    /// GPU-spoofing settings steamwebhelper needs and not just the compat flag.
    open func applyLauncherFixes() {
        LauncherFixes.apply(to: bottle, launcher: .steam)
    }

    /// Shared with `whisky launch`: resolves the GameDB profile and the user's
    /// overrides, records the bottle for this App ID, and hands `-applaunch`
    /// to the client. The task reports request delivery; game appearance is
    /// confirmed separately through process polling. The install URL is known,
    /// which saves a library rescan.
    @discardableResult
    open func launchGame(_ game: SteamGame) throws -> Task<Wine.ProgramRunResult, any Error>? {
        if let root = SteamLibrary.detectInstall(bottleURL: bottle.url) {
            receipts[game.appId] = SteamLaunchReceipt(steamRoot: root)
        }
        // The orchestrator has started the client or found it running already.
        return try SteamLauncher.launch(
            appId: game.appId, bottle: bottle, installURL: game.installURL, clientIsRunning: true
        )
    }

    open func killProcess(winePID: Int32) async {
        await Wine.gracefulKillProcess(winePID: winePID, bottle: bottle)
    }

    open func clientDidBecomeReady() {}

    open func shutdown() {
        cancelClientStartup()
    }
}

/// Owns only pre-launch preparation. Handoff releases cancellation ownership
/// so cancelling a waiting request preserves a client that has started.
@MainActor
final class SteamClientStartup {
    private var task: Task<Void, Never>?
    private var id: UUID?

    func start(_ makeTask: (@escaping @MainActor () -> Void) -> Task<Void, Never>) {
        cancel()
        let id = UUID()
        self.id = id
        task = makeTask { [weak self] in
            guard self?.id == id else { return }
            self?.task = nil
            self?.id = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        id = nil
    }
}
