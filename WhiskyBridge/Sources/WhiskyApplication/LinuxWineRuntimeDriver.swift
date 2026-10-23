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
import WhiskyCore

/// Linux Wine runtime driver backed by a relocatable Wine runtime tree
/// (the ge-proton Linux build: `bin/wine`, `bin/wineserver`, bundled `lib`).
///
/// Process observation feeds the shared launch state machine directly; there is
/// no Combine or Steam client tracking on this host. A program counts as
/// running while its Wine process lives and, after a launcher hands off and
/// exits, while the bottle's wineserver still serves processes.
@MainActor
public final class LinuxWineRuntimeDriver: LibraryRuntimeDriver {
    public private(set) var snapshot = LibraryRuntimeDriverSnapshot()
    private let channel = RuntimeEventChannel<LibraryRuntimeDriverEvent>()
    public let host: LinuxWineHost
    private let logDirectory: URL
    private var processes: [String: Process] = [:]
    private var entries: [String: LibraryEntry] = [:]
    private var watchers: [String: Task<Void, Never>] = [:]

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
        return [.launch, .cancelLaunch, .stop]
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
        for entry in newEntries where entry.bottleURL == containerURL {
            entries[entry.id] = entry
        }
        let ids = Set(newEntries.map(\.id))
        snapshot.observation.endedEntryIDs = snapshot.observation.endedEntryIDs.intersection(ids)
        snapshot.observation.completedAt = snapshot.observation.completedAt.filter { ids.contains($0.key) }
        publish()
    }

    public func launchProgram(
        _ request: LibraryLaunchRequest, onStarted: @escaping @MainActor () -> Void
    ) async -> LaunchResult {
        let entry = request.entry
        guard host.canExecute else {
            return .launchFailed(
                programName: entry.name,
                errorDescription: host.unavailableReason ?? "The Wine runtime cannot run on this host"
            )
        }
        guard let executable = executable(for: request) else {
            return .launchFailed(programName: entry.name, errorDescription: "Launch target unavailable")
        }
        guard FileManager.default.fileExists(atPath: executable.path) else {
            return .launchFailed(
                programName: entry.name,
                errorDescription: "Executable is missing: \(executable.lastPathComponent)"
            )
        }
        if processes[entry.id]?.isRunning == true {
            return .launchFailed(programName: entry.name, errorDescription: "This program is already running")
        }
        let configuration = await LinuxLaunchConfiguration.load(
            container: entry.bottleURL,
            executable: executable
        )
        // Wine resolves the executable against the working directory. Passing a
        // relative name keeps the parent directory out of the command line and
        // gives the game its own folder as the current directory, which many
        // titles rely on to find their data.
        let process = host.process(
            host.loader,
            arguments: Self.wineArguments(for: executable) + configuration.arguments,
            prefix: entry.bottleURL,
            environment: configuration.environment
        )
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        // Protocol traffic owns the bridge's stdout; game output goes to a log.
        let log = openLog(for: executable)
        process.standardOutput = log?.handle ?? FileHandle.nullDevice
        process.standardError = log?.handle ?? FileHandle.nullDevice
        let id = entry.id
        let exit = ExitRecorder()
        process.terminationHandler = { [weak self] finished in
            exit.record(finished.terminationStatus)
            Task { @MainActor in self?.processDidTerminate(id: id, process: finished) }
        }
        do {
            try process.run()
        } catch {
            try? log?.handle.close()
            return .launchFailed(
                programName: entry.name,
                errorDescription: "Could not start Wine: \(error.localizedDescription)"
            )
        }
        try? log?.handle.close()
        processes[id] = process
        entries[id] = entry

        // Report a startup failure instead of a launch that silently vanishes.
        let deadline = ContinuousClock.now + Self.startupWindow
        while ContinuousClock.now < deadline, exit.status == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if let status = exit.status, status != 0 {
            let tail = log.map { Self.tail(of: $0.url) } ?? ""
            let detail = tail.isEmpty ? "" : ": \(tail)"
            return .launchFailed(
                programName: entry.name,
                errorDescription: "Wine exited with status \(status)\(detail)"
            )
        }

        onStarted()
        snapshot.observation.runningEntryIDs.insert(id)
        snapshot.observation.endedEntryIDs.remove(id)
        snapshot.observation.revision &+= 1
        publish()
        if exit.status != nil, processes[id] == nil {
            // A launcher exited cleanly inside the window; follow the server.
            watchServer(id: id, prefix: entry.bottleURL)
        }
        return .launchedSuccessfully(programName: entry.name)
    }

    public func programDidStart(_ request: LibraryLaunchRequest) {
        // Running state is published at spawn; there is no separate PID probe.
    }

    public func launchSteam(_ entry: LibraryEntry) {
        channel.send(.failure("Steam launches require the macOS Wine host adapter"))
    }

    public func cancelSteamLaunch(_ entry: LibraryEntry) {}

    public func stop(_ entry: LibraryEntry) async {
        watchers.removeValue(forKey: entry.id)?.cancel()
        processes[entry.id]?.terminate()
        _ = try? await host.run(host.wineserver, arguments: ["-k"], prefix: entry.bottleURL, timeout: .seconds(10))
        watchers.removeValue(forKey: entry.id)?.cancel()
        markEnded(entry.id)
    }

    public func stopTracking() {
        // Launched games outlive helper tracking, matching the native driver.
        for watcher in watchers.values {
            watcher.cancel()
        }
        watchers.removeAll()
    }

    /// `wine` arguments for a Windows file, relative to its own directory.
    static func wineArguments(for executable: URL) -> [String] {
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
        guard snapshot.observation.runningEntryIDs.contains(id) else { return }
        guard let entry = entries[id] else {
            markEnded(id)
            return
        }
        // Launchers often start the game and exit; the game keeps the
        // bottle's wineserver alive until it ends.
        watchServer(id: id, prefix: entry.bottleURL)
    }

    private func watchServer(id: String, prefix: URL) {
        watchers[id]?.cancel()
        let host = host
        watchers[id] = Task { [weak self] in
            while !Task.isCancelled {
                guard await host.serverRunning(prefix: prefix) else { break }
                try? await Task.sleep(for: .seconds(3))
            }
            guard !Task.isCancelled else { return }
            self?.watchers.removeValue(forKey: id)
            self?.markEnded(id)
        }
    }

    private func markEnded(_ id: String) {
        guard snapshot.observation.runningEntryIDs.contains(id) else { return }
        snapshot.observation.runningEntryIDs.remove(id)
        snapshot.observation.endedEntryIDs.insert(id)
        snapshot.observation.completedAt[id] = Date()
        snapshot.observation.revision &+= 1
        publish()
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

    private func openLog(for executable: URL) -> (url: URL, handle: FileHandle)? {
        let manager = FileManager.default
        guard (try? manager.createDirectory(at: logDirectory, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        pruneLogs()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = executable.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
        let url = logDirectory.appendingPathComponent("\(formatter.string(from: Date()))-\(stem).log")
        guard manager.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url)
        else { return nil }
        return (url, handle)
    }

    /// Keeps the newest 30 program logs.
    private func pruneLogs() {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: logDirectory.path) else { return }
        let logs = names.filter { $0.hasSuffix(".log") }.sorted()
        for name in logs.dropLast(30) {
            try? manager.removeItem(at: logDirectory.appendingPathComponent(name))
        }
    }

    static func tail(of url: URL, lines count: Int = 6) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        let text = String(decoding: data.suffix(16 * 1_024), as: UTF8.self)
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
