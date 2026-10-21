//
//  WineLibraryRuntimeDriver.swift
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

import Combine
import Foundation
import WhiskyCore

/// Wine and Combine stay inside the platform adapter; frontends consume core events.
@MainActor
public final class WineLibraryRuntimeDriver: LibraryRuntimeDriver {
    public private(set) var snapshot = LibraryRuntimeDriverSnapshot()
    private let channel = RuntimeEventChannel<LibraryRuntimeDriverEvent>()
    private let bottleResolver: @MainActor (URL) -> Bottle?
    private let driverFactory: @MainActor (Bottle) -> any SteamClientDriver
    private let tracker: GameActivityTracker
    private var clients: [URL: SteamClientOrchestrator] = [:]
    private var subscriptions: [URL: Set<AnyCancellable>] = [:]
    private var trackerSubscriptions = Set<AnyCancellable>()
    private var configurationIDs: [URL: UUID] = [:]
    var steamTiming = SteamClientOrchestrator.Timing()
    typealias ProgramRunner = @MainActor (Program, Bool, @escaping @MainActor () -> Void) async -> LaunchResult
    var programRunner: ProgramRunner = { await $0.launchWithUserMode(useTerminal: $1, onStarted: $2) }

    public init(
        bottleResolver: @escaping @MainActor (URL) -> Bottle?,
        driverFactory: @escaping @MainActor (Bottle) -> any SteamClientDriver = { WineSteamClientDriver(bottle: $0) },
        tracker: GameActivityTracker = .shared
    ) {
        self.bottleResolver = bottleResolver
        self.driverFactory = driverFactory
        self.tracker = tracker
        tracker.$observation.sink { [weak self] observation in
            self?.snapshot.observation = observation
            self?.publish()
        }.store(in: &trackerSubscriptions)
        tracker.$queryFailures.sink { [weak self] failures in
            self?.snapshot.queryFailures = failures
            self?.publish()
        }.store(in: &trackerSubscriptions)
    }

    public func events() -> AsyncStream<LibraryRuntimeDriverEvent> {
        channel.stream(replaying: [.changed(snapshot)])
    }

    public func capabilities(for entry: LibraryEntry) -> LibraryRuntimeCapabilities {
        guard bottleResolver(entry.bottleURL) != nil else { return [] }
        switch entry.launch {
        case .program: return [.launch, .cancelLaunch, .terminal]
        case .steam: return [.launch, .cancelLaunch, .stop]
        }
    }

    public func retainContainers(_ urls: Set<URL>) {
        for url in clients.keys where !urls.contains(url) {
            removeClient(at: url)
        }
        configurationIDs = configurationIDs.filter { urls.contains($0.key) }
        tracker.retainBottles(urls)
        snapshot.steamPhases = snapshot.steamPhases.filter { urls.contains($0.key) }
        snapshot.steamRunning = snapshot.steamRunning.filter { urls.contains($0.key) }
        publish()
    }

    public func configure(entries: [LibraryEntry], containerURL: URL) async {
        guard let bottle = bottleResolver(containerURL) else { return }
        let generation = UUID()
        configurationIDs[containerURL] = generation
        await tracker.configure(entries: entries, bottle: bottle)
        guard configurationIDs[containerURL] == generation else { return }
        let games = SteamLibrary.enumerate(bottleURL: containerURL)
        if games.isEmpty {
            removeClient(at: containerURL)
        } else {
            client(for: bottle).startTracking(games: games)
        }
    }

    public func launchProgram(
        _ request: LibraryLaunchRequest, onStarted: @escaping @MainActor () -> Void
    ) async -> LaunchResult {
        guard let bottle = bottleResolver(request.entry.bottleURL),
              let executable = executable(for: request)
        else { return .launchFailed(programName: request.entry.name, errorDescription: "Launch target unavailable") }
        let program = bottle.programs.first { $0.url == executable } ?? Program(url: executable, bottle: bottle)
        return await programRunner(program, request.mode == .terminal, onStarted)
    }

    public func programDidStart(_ request: LibraryLaunchRequest) {
        guard let bottle = bottleResolver(request.entry.bottleURL), let executable = executable(for: request)
        else { return }
        tracker.track(request.entry, executable: executable, bottle: bottle)
    }

    public func launchSteam(_ entry: LibraryEntry) {
        guard case let .steam(appID) = entry.launch, let bottle = bottleResolver(entry.bottleURL),
              let game = SteamLibrary.enumerate(bottleURL: bottle.url).first(where: { $0.appId == appID })
        else {
            channel.send(.failure(String(localized: "library.launch.steamGameMissing")))
            return
        }
        tracker.select(entry)
        client(for: bottle).launch(game)
    }

    public func cancelSteamLaunch(_ entry: LibraryEntry) {
        guard case let .steam(appID) = entry.launch else { return }
        clients[entry.bottleURL]?.cancelLaunch(appID: appID)
    }

    public func stop(_ entry: LibraryEntry) async {
        guard case let .steam(appID) = entry.launch, let bottle = bottleResolver(entry.bottleURL),
              let game = SteamLibrary.enumerate(bottleURL: bottle.url).first(where: { $0.appId == appID })
        else { return }
        await client(for: bottle).stop(game)
    }

    public func stopTracking() {
        configurationIDs.removeAll()
        for client in clients.values {
            client.stop()
        }
    }

    private func executable(for request: LibraryLaunchRequest) -> URL? {
        if let executable = request.executableURL {
            return executable
        }
        guard case let .program(executable) = request.entry.launch, request.entry.source != .folder else { return nil }
        return executable
    }

    private func client(for bottle: Bottle) -> SteamClientOrchestrator {
        let url = bottle.url
        if let existing = clients[url], existing.bottle === bottle {
            return existing
        }
        removeClient(at: url)
        let made = SteamClientOrchestrator(bottle: bottle, driver: driverFactory(bottle), timing: steamTiming)
        clients[url] = made
        var cancellables = Set<AnyCancellable>()
        made.$phases.sink { [weak self] phases in
            self?.snapshot.steamPhases[url] = phases
            self?.publish()
        }.store(in: &cancellables)
        made.$runningAppIds.sink { [weak self] running in
            self?.snapshot.steamRunning[url] = running
            self?.publish()
        }.store(in: &cancellables)
        made.$launchError.compactMap { $0 }.sink { [weak self] message in
            self?.channel.send(.failure(message))
        }.store(in: &cancellables)
        subscriptions[url] = cancellables
        return made
    }

    private func removeClient(at url: URL) {
        clients.removeValue(forKey: url)?.stop()
        subscriptions[url] = nil
        snapshot.steamPhases[url] = nil
        snapshot.steamRunning[url] = nil
        publish()
    }

    private func publish() {
        snapshot.revision &+= 1
        channel.send(.changed(snapshot))
    }
}
