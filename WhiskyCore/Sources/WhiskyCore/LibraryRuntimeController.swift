//
//  LibraryRuntimeController.swift
//  WhiskyCore
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

/// Shared launch state machine, independent of UI observation and host APIs.
@MainActor
public final class LibraryRuntimeController: LibraryRuntime {
    public private(set) var state = LibraryRuntimeState()
    private let driver: any LibraryRuntimeDriver
    private let channel = RuntimeEventChannel<LibraryRuntimeEvent>()
    private var observationTask: Task<Void, Never>?
    private var requests: [String: UUID] = [:]
    private var entries: [String: LibraryEntry] = [:]
    private var preparations: [String: Task<Void, Never>] = [:]
    private var deadlines: [String: Task<Void, Never>] = [:]
    private var driverRevision: UInt64?
    private let launchTimeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        driver: any LibraryRuntimeDriver, launchTimeout: Duration = .seconds(120),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.driver = driver
        self.launchTimeout = launchTimeout
        self.sleep = sleep
        apply(driver.snapshot)
        let events = driver.events()
        observationTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                switch event {
                case let .changed(snapshot): self?.apply(snapshot)
                case let .failure(message): self?.channel.send(.failure(.driver(message)))
                }
            }
        }
    }

    public func events() -> AsyncStream<LibraryRuntimeEvent> {
        channel.stream(replaying: [.state(state)])
    }

    public func capabilities(for entry: LibraryEntry) -> LibraryRuntimeCapabilities {
        driver.capabilities(for: entry)
    }

    public func retainContainers(_ urls: Set<URL>) {
        let previous = state
        for entry in entries.values where !urls.contains(entry.bottleURL) {
            clear(entry.id, cancel: true)
        }
        if previous != state {
            publish()
        }
        driver.retainContainers(urls)
        apply(driver.snapshot)
    }

    public func configure(entries: [LibraryEntry], containerURL: URL) async {
        await driver.configure(entries: entries, containerURL: containerURL)
    }

    public func launch(_ request: LibraryLaunchRequest) {
        apply(driver.snapshot)
        let entry = request.entry
        guard capabilities(for: entry).contains(.launch),
              request.mode != .terminal || capabilities(for: entry).contains(.terminal)
        else {
            channel.send(.failure(.unavailable(entryID: entry.id)))
            return
        }
        let current = state.launch.state(for: entry)
        guard current == .idle else { return }
        switch entry.launch {
        case .steam: driver.launchSteam(entry)
        case .program: launchProgram(request)
        }
    }

    public func cancelLaunch(for entry: LibraryEntry) {
        switch entry.launch {
        case .steam: driver.cancelSteamLaunch(entry)
        case .program:
            guard state.launch.programPreparing.contains(entry.id) || state.launch.programLaunching.contains(entry.id)
            else { return }
            clear(entry.id, cancel: true)
            publish()
        }
    }

    public func stop(_ entry: LibraryEntry) async {
        guard capabilities(for: entry).contains(.stop) else { return }
        await driver.stop(entry)
    }

    /// UI polling can end while application-scoped game activity tracking continues.
    public func stopTracking() {
        driver.stopTracking()
        apply(driver.snapshot)
    }

    private func launchProgram(_ request: LibraryLaunchRequest) {
        let entry = request.entry
        let id = entry.id
        let token = UUID()
        requests[id] = token
        entries[id] = entry
        state.launch.programPreparing.insert(id)
        publish()
        setDeadline(for: entry, token: token)
        preparations[id] = Task { [weak self, driver] in
            guard !Task.isCancelled else { return }
            let result = await driver.launchProgram(request) { [weak self] in
                guard let self, self.requests[id] == token,
                      self.state.launch.programPreparing.contains(id)
                else { return }
                self.state.launch.programPreparing.remove(id)
                self.state.launch.programLaunching.insert(id)
                self.publish()
                self.setDeadline(for: entry, token: token)
                driver.programDidStart(request)
            }
            guard let self, requests[id] == token else { return }
            preparations[id] = nil
            if result.errorDescription != nil, !state.launch.runningEntryIDs.contains(id) {
                clear(id, cancel: false)
                publish()
            }
            channel.send(.launchResult(entryID: id, result: result))
        }
    }

    private func setDeadline(for entry: LibraryEntry, token: UUID) {
        let id = entry.id
        deadlines.removeValue(forKey: id)?.cancel()
        let sleep = sleep
        let timeout = launchTimeout
        deadlines[id] = Task { [weak self] in
            do { try await sleep(timeout) } catch { return }
            guard !Task.isCancelled, let self, requests[id] == token,
                  state.launch.programPreparing.contains(id) || state.launch.programLaunching.contains(id)
            else { return }
            let queryError = state.queryFailures[entry.bottleURL]
            clear(id, cancel: true)
            publish()
            channel.send(.failure(.launchTimedOut(entryID: id, queryError: queryError)))
        }
    }

    private func clear(_ id: String, cancel: Bool) {
        requests[id] = nil
        entries[id] = nil
        if cancel {
            preparations[id]?.cancel()
        }
        preparations[id] = nil
        deadlines.removeValue(forKey: id)?.cancel()
        state.launch.programPreparing.remove(id)
        state.launch.programLaunching.remove(id)
    }

    private func apply(_ snapshot: LibraryRuntimeDriverSnapshot) {
        if let driverRevision, snapshot.revision <= driverRevision {
            return
        }
        driverRevision = snapshot.revision
        let previous = state
        let observationChanged = previous.observation != snapshot.observation
        state.queryFailures = snapshot.queryFailures
        state.observation = snapshot.observation
        state.launch.runningEntryIDs = snapshot.observation.runningEntryIDs
        state.launch.queryFailureBottles = Set(snapshot.queryFailures.keys)
        state.launch.steamPhases = snapshot.steamPhases
        state.launch.steamLaunching = snapshot.steamPhases.mapValues { Set($0.keys) }
        state.launch.steamRunning = snapshot.steamRunning
        let ended = observationChanged ? snapshot.observation.endedEntryIDs : []
        for id in snapshot.observation.runningEntryIDs.union(ended) {
            // A confirmed process can precede the launch command's return value.
            deadlines.removeValue(forKey: id)?.cancel()
            state.launch.programPreparing.remove(id)
            state.launch.programLaunching.remove(id)
            if ended.contains(id) {
                clear(id, cancel: false)
            }
        }
        if previous != state {
            publish()
        }
    }

    private func publish() {
        channel.send(.state(state))
    }

    deinit {
        observationTask?.cancel()
        for task in preparations.values {
            task.cancel()
        }
        for task in deadlines.values {
            task.cancel()
        }
    }
}
