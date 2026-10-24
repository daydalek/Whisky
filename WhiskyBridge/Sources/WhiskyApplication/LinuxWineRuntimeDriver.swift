//
//  LinuxWineRuntimeDriver.swift
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
import WhiskyCore

/// Linux Wine runtime driver backed by a relocatable Wine runtime tree
/// (the ge-proton Linux build: `bin/wine`, `bin/wineserver`, bundled `lib`).
///
/// Windows process observations feed the shared state machine and activity store.
/// Each game is matched by its executable names and the user's launch selection.
@MainActor
public final class LinuxWineRuntimeDriver: LibraryRuntimeDriver {
    public private(set) var snapshot = LibraryRuntimeDriverSnapshot()
    private let channel = RuntimeEventChannel<LibraryRuntimeDriverEvent>()
    public let host: LinuxWineHost
    private let logDirectory: URL
    private var processes: [String: Process] = [:]
    private var entries: [String: LibraryEntry] = [:]
    private var observationTask: Task<Void, Never>?
    private var names: [String: Set<String>] = [:]
    private var selections: [URL: [String: String]] = [:]
    private var clocks: [URL: GameActivityClock] = [:]
    private var completions: [String: Date] = [:]
    private var histories: [String: LinuxProgramRunHistory] = [:]
    private let activity = LinuxActivityStore()
    private var polling = false

    /// How long a fresh Wine process is watched for an immediate failure
    /// (missing libraries, an absent translator, a broken prefix).
    static let startupWindow: Duration = .seconds(3)

    public init(host: LinuxWineHost, logDirectory: URL = HostPaths.logs()) {
        self.host = host
        self.logDirectory = logDirectory
    }

    public convenience init?(runtimeURL: URL) {
        guard let host = LinuxWineHost(runtimeURL: runtimeURL) else { return nil }
        self.init(host: host)
    }

    public func events() -> AsyncStream<LibraryRuntimeDriverEvent> {
        channel.stream(replaying: [.changed(snapshot)])
    }

    public func capabilities(for entry: LibraryEntry) -> LibraryRuntimeCapabilities {
        guard case .program = entry.launch else { return [] }
        return [.launch, .cancelLaunch]
    }

    public func retainContainers(_ urls: Set<URL>) {
        let retained = entries.filter { urls.contains($0.value.bottleURL) }
        snapshot.observation.endedEntryIDs = snapshot.observation.endedEntryIDs
            .intersection(retained.keys)
        snapshot.observation.completedAt = snapshot.observation.completedAt
            .filter { retained[$0.key] != nil }
        entries = entries.filter { urls.contains($0.value.bottleURL) || processes[$0.key] != nil }
        publish()
    }

    public func configure(entries newEntries: [LibraryEntry], containerURL: URL) async {
        entries = entries.filter { $0.value.bottleURL != containerURL || processes[$0.key] != nil }
        for entry in newEntries where entry.bottleURL == containerURL {
            entries[entry.id] = entry
            let selected = executable(for: .init(entry: entry))
            names[entry.id] = await Task.detached {
                switch entry.launch {
                case let .program(url):
                    if entry
                        .source == .folder {
                        return SteamLibrary.executableNames(under: url, selectedURL: selected)
                    }
                    return Set([url.lastPathComponent.lowercased()])
                case let .steam(appID):
                    let game = SteamLibrary.enumerate(bottleURL: containerURL).first { $0.appId == appID }
                    return game.map { SteamLibrary.executableNames(under: $0.installURL) } ?? []
                }
            }.value
        }
        if observationTask == nil {
            observationTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.poll()
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                }
            }
        }
        publish()
    }

    public func launchProgram(
        _ request: LibraryLaunchRequest, onStarted: @escaping @MainActor () -> Void
    ) async -> LaunchResult {
        let entry = request.entry
        do {
            let executable = try launchTarget(request)
            let configuration = try await LinuxLaunchConfiguration.load(
                container: entry.bottleURL,
                executable: executable
            )
            try await LinuxWineConfiguration.prepare(container: entry.bottleURL, host: host)
            try Task.checkCancellation()
            let started = try spawn(entry, executable: executable, configuration: configuration)
            let process = started.process, run = started.history, exit = started.exit
            do {
                let deadline = ContinuousClock.now + Self.startupWindow
                while ContinuousClock.now < deadline, exit.status == nil {
                    try await Task.sleep(for: .milliseconds(100))
                }
                try Task.checkCancellation()
            } catch {
                if process.isRunning {
                    process.terminate()
                }
                if let run = histories.removeValue(forKey: entry.id) {
                    try run.finish(exitCode: -1)
                }
                processes.removeValue(forKey: entry.id)
                throw error
            }
            if let status = exit.status, status != 0 {
                throw BridgeFailure("launch_failed", "Wine exited with status \(status): \(Self.tail(of: run.log))")
            }
            onStarted()
            await poll()
            if exit.status == 0, !snapshot.observation.runningEntryIDs.contains(entry.id) {
                snapshot.observation.endedEntryIDs.insert(entry.id)
                snapshot.observation.completedAt[entry.id] = Date()
                snapshot.observation.revision &+= 1
                publish()
            }
            return .launchedSuccessfully(programName: entry.name)
        } catch {
            return .launchFailed(programName: entry.name, errorDescription: error.localizedDescription)
        }
    }

    private func launchTarget(_ request: LibraryLaunchRequest) throws -> URL {
        guard host.canExecute else {
            throw BridgeFailure(
                "runtime_unavailable",
                host.unavailableReason ?? "The Wine runtime cannot run on this host"
            )
        }
        guard let executable = executable(for: request), FileManager.default.fileExists(atPath: executable.path) else {
            throw BridgeFailure("file_missing", "Launch target unavailable")
        }
        guard processes[request.entry.id]?.isRunning != true else {
            throw BridgeFailure("runtime_busy", "This program is already running")
        }
        return executable
    }

    private func spawn(_ entry: LibraryEntry, executable: URL, configuration: LinuxLaunchConfiguration) throws
        -> StartedWineProcess {
        let process = host.process(
            host.loader,
            arguments: configuration.wineArguments(for: executable),
            prefix: entry.bottleURL,
            environment: configuration.environment
        )
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        let run = try LinuxProgramRunHistory.begin(
            container: entry.bottleURL,
            executable: executable,
            logs: logDirectory
        )
        let log = try FileHandle(forWritingTo: run.log)
        defer { try? log.close() }
        process.standardOutput = log
        process.standardError = log
        let id = entry.id
        let exit = ExitRecorder()
        process.terminationHandler = { [weak self] finished in
            exit.record(finished.terminationStatus)
            Task { @MainActor in self?.processDidTerminate(id: id, process: finished) }
        }
        do {
            try process.run()
        } catch { try run.finish(exitCode: -1)
            throw error
        }
        processes[id] = process
        histories[id] = run
        entries[id] = entry
        selections[entry.bottleURL, default: [:]][executable.lastPathComponent.lowercased()] = id
        return StartedWineProcess(process: process, history: run, exit: exit)
    }

    public func programDidStart(_ request: LibraryLaunchRequest) {
        // The configured process observer publishes confirmed Windows process state.
    }

    public func launchSteam(_ entry: LibraryEntry) {
        channel.send(.failure("Steam launches require the macOS Wine host adapter"))
    }

    public func cancelSteamLaunch(_ entry: LibraryEntry) {}

    public func stop(_ entry: LibraryEntry) async {
        channel.send(.failure("Use the Processes page to select the Windows process to terminate"))
    }

    public func stopTracking() {
        observationTask?.cancel()
        observationTask = nil
        for entry in entries.values {
            do {
                try activity.release(entry)
            } catch {
                channel.send(.failure(error.localizedDescription))
            }
        }
        clocks.removeAll()
    }

    /// `wine` arguments for a Windows file, relative to its own directory.
    nonisolated static func wineArguments(for executable: URL) -> [String] {
        let name = executable.lastPathComponent
        switch executable.pathExtension.lowercased() {
        case "msi": return ["msiexec", "/i", name]
        case "bat", "cmd": return ["cmd", "/c", name]
        case "exe", "com": return [name]
        default: return ["start", "/unix", executable.path]
        }
    }

    private func processDidTerminate(id: String, process: Process) {
        guard processes[id] === process else { return }
        processes.removeValue(forKey: id)
        if let run = histories.removeValue(forKey: id) {
            do {
                try run.finish(exitCode: process.terminationStatus)
            } catch {
                channel.send(.failure("Could not save run history: \(error.localizedDescription)"))
            }
        }
        Task { [weak self] in await self?.poll() }
    }

    private func executable(for request: LibraryLaunchRequest) -> URL? {
        if let executable = request.executableURL {
            return executable
        }
        guard case let .program(target) = request.entry.launch else { return nil }
        guard request.entry.source == .folder else { return target }
        // A folder entry names its folder, never a file: the executable is the
        // one the user picked, recorded in the folder library.
        guard let library = try? FolderGameLibrary.load(bottleURL: request.entry.bottleURL),
              let executable = library.executable(for: target, bottleURL: request.entry.bottleURL)
        else { return nil }
        return executable
    }

    static func tail(of url: URL, lines count: Int = 6) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        let text = String(bytes: data.suffix(16 * 1_024), encoding: .utf8) ?? ""
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.suffix(count).joined(separator: " | ")
    }

    private func publish() {
        snapshot.revision &+= 1
        channel.send(.changed(snapshot))
    }
}

extension LinuxWineRuntimeDriver {
    public func poll() async {
        guard !polling else { return }
        polling = true
        defer { polling = false }
        let probe = LinuxWineProcessHost(host: host)
        for container in Set(entries.values.map(\.bottleURL)) {
            let targets = entries.values.filter { $0.bottleURL == container }
            do {
                let records = try await probe.listProcesses(in: container)
                try Task.checkCancellation()
                let runningNames = Set(records.map { $0.name.lowercased() })
                let candidates = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, names[$0.id] ?? []) })
                let matched = GameActivityClock.match(
                    executables: candidates,
                    runningNames: runningNames,
                    preferred: selections[container] ?? [:]
                )
                let old = snapshot.observation.runningEntryIDs.intersection(targets.map(\.id))
                let date = Date()
                for id in old.subtracting(matched) {
                    completions[id] = date
                }
                snapshot.observation.runningEntryIDs.subtract(old)
                snapshot.observation.runningEntryIDs.formUnion(matched)
                for id in old.subtracting(matched) {
                    snapshot.observation.endedEntryIDs.insert(id)
                    snapshot.observation.completedAt[id] = date
                    selections[container] = selections[container]?.filter { $0.value != id }
                }
                snapshot.observation.endedEntryIDs.subtract(matched)
                snapshot.observation.revision &+= 1
                let samples = clocks[container, default: GameActivityClock()].sample(
                    running: matched, at: date, uptime: ProcessInfo.processInfo.systemUptime
                )
                try persist(targets: targets, samples: samples, at: date)
                snapshot.queryFailures[container] = nil
            } catch is CancellationError {
                return
            } catch {
                clocks[container]?.reset()
                snapshot.queryFailures[container] = error.localizedDescription
            }
        }
        publish()
    }

    private func persist(targets: [LibraryEntry], samples: [String: TimeInterval], at date: Date) throws {
        for entry in targets {
            if let ended = completions[entry.id] {
                try activity.sample(entry, seconds: 0, at: ended, completed: true)
                completions[entry.id] = nil
            }
            if let seconds = samples[entry.id] {
                try activity.sample(entry, seconds: seconds, at: date)
            }
        }
    }
}

private struct StartedWineProcess {
    let process: Process
    let history: LinuxProgramRunHistory
    let exit: ExitRecorder
}

/// The exit status, written from Foundation's termination thread.
private final class ExitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?
    var status: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func record(_ status: Int32) {
        lock.lock()
        value = status
        lock.unlock()
    }
}
