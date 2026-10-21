//
//  GameActivityTracker.swift
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

/// Kept for the application's lifetime so navigating away from the library keeps counting.
@MainActor
public final class GameActivityTracker: ObservableObject {
    public static let shared = GameActivityTracker()
    @Published public private(set) var error: String?
    @Published public private(set) var lastUpdatedEntryID: String?
    @Published public private(set) var queryFailures: [URL: String] = [:]
    @Published public private(set) var observation = Observation()
    private var runningByBottle: [URL: Set<String>] = [:]
    private var polling = false
    private var pollAgain = false
    private var sleepTask: Task<Void, Never>?
    private struct SampleBatch {
        let targets: [LibraryEntry]
        let running: Set<String>
        let date: Date
    }

    private var pendingSamples: [URL: SampleBatch] = [:]
    private var persistenceTask: Task<Void, Never>?
    private var persistenceFailures: [String: String] = [:]
    private var pendingLaunches: [String: Date] = [:]
    private var missingSince: [String: Date] = [:]
    private var pendingCompletions: [String: (entry: LibraryEntry, date: Date)] = [:]
    var idlePollInterval: Duration = .seconds(10)
    var pendingPollInterval: Duration = .seconds(2)
    var now: () -> Date = Date.init
    private var cancellables = Set<AnyCancellable>()

    public init(store: GameActivityStore? = .shared, entryID: String? = nil) {
        NotificationCenter.default.publisher(for: GameActivityStore.didUpdateNotification, object: store)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self, let id = notification.userInfo?[GameActivityStore.entryIDKey] as? String else { return }
                if let entryID, id != entryID {
                    return
                }
                self.lastUpdatedEntryID = id
                self.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    private var entries: [URL: [LibraryEntry]] = [:]
    private var bottles: [URL: Bottle] = [:]
    private var names: [URL: [String: Set<String>]] = [:]
    private struct TrackingKey: Hashable {
        let bottle: URL
        let identity: String
    }

    private var clocks: [TrackingKey: GameActivityClock] = [:]
    private var task: Task<Void, Never>?
    private struct Selection {
        let identity: String
        let date: Date
        var observed = false
    }

    private var selections: [URL: [String: Selection]] = [:]
    private let ownerID = UUID()
    private var generations: [TrackingKey: UInt64] = [:]
    private var sequences: [TrackingKey: UInt64] = [:]

    // Package tests drive the same polling path with deterministic process observations.
    var automaticallyPolls = true
    var wineserverProbe: @MainActor (Bottle) async throws -> Bool = { try await Wine.probeWineserver(for: $0) }
    var processProbe: @MainActor (Bottle) async throws -> [WineProcess] = { try await Wine.listProcesses(for: $0) }

    /// A library launch disambiguates games that share an executable filename.
    public func track(_ entry: LibraryEntry, executable: URL, bottle: Bottle) {
        bottles[bottle.url] = bottle
        if entries[bottle.url]?.contains(where: { $0.metadataIdentity == entry.metadataIdentity }) != true {
            entries[bottle.url, default: []].append(entry)
        }
        let name = executable.lastPathComponent.lowercased()
        names[bottle.url, default: [:]][entry.metadataIdentity, default: []].insert(name)
        select(entry)
    }

    public func select(_ entry: LibraryEntry) {
        for name in names[entry.bottleURL]?[entry.metadataIdentity] ?? [] {
            selections[entry.bottleURL, default: [:]][name] = Selection(
                identity: entry.metadataIdentity, date: now()
            )
        }
        pendingLaunches[entry.id] = now().addingTimeInterval(120)
        requestPoll()
    }

    public func configure(entries: [LibraryEntry], bottle: Bottle) async {
        self.entries[bottle.url] = entries
        bottles[bottle.url] = bottle
        let targets = self.entries[bottle.url] ?? []
        let url = bottle.url
        names[url] = await Task.detached {
            let steam = SteamLibrary.enumerate(bottleURL: url)
            let folders = try? FolderGameLibrary.load(bottleURL: url)
            return Dictionary(uniqueKeysWithValues: targets.map { entry in
                let executables: Set<String>
                switch entry.launch {
                case let .steam(appID):
                    executables = steam.first { $0.appId == appID }.map {
                        let selected = try? SteamGameProgram.selectedURL(
                            appID: appID, installURL: $0.installURL, bottleURL: url
                        )
                        return SteamLibrary.executableNames(under: $0.installURL, selectedURL: selected)
                    } ?? []
                case let .program(program):
                    let executable = entry.source == .folder
                        ? folders?.executable(for: program, bottleURL: url) : program
                    if entry.source == .folder {
                        executables = SteamLibrary.executableNames(under: program, selectedURL: executable)
                    } else {
                        executables = executable.map { Set([$0.lastPathComponent.lowercased()]) } ?? []
                    }
                }
                return (entry.metadataIdentity, executables)
            })
        }.value
        start()
    }

    /// Wakes the existing scheduler; each poll remains serialized across actor suspension points.
    public func requestPoll() {
        guard automaticallyPolls else { return }
        if polling {
            pollAgain = true
        }
        sleepTask?.cancel()
        start()
    }

    private func start() {
        guard automaticallyPolls, task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await poll(waitForPersistence: false)
                guard !Task.isCancelled else { return }
                if pollAgain {
                    pollAgain = false
                    continue
                }
                let delay = pendingLaunches.isEmpty && missingSince.isEmpty ? idlePollInterval : pendingPollInterval
                let sleeper = Task<Void, Never> { try? await Task.sleep(for: delay) }
                sleepTask = sleeper
                await sleeper.value
                sleepTask = nil
            }
        }
    }

    public func stopPolling() async {
        let running = task
        running?.cancel()
        sleepTask?.cancel()
        await running?.value
        await persistenceTask?.value
        task = nil
        sleepTask = nil
    }

    public func retainBottles(_ urls: Set<URL>) {
        entries = entries.filter { urls.contains($0.key) }
        bottles = bottles.filter { urls.contains($0.key) }
        names = names.filter { urls.contains($0.key) }
        clocks = clocks.filter { urls.contains($0.key.bottle) }
        generations = generations.filter { urls.contains($0.key.bottle) }
        sequences = sequences.filter { urls.contains($0.key.bottle) }
        selections = selections.filter { urls.contains($0.key) }
        runningByBottle = runningByBottle.filter { urls.contains($0.key) }
        publishObservation(completed: [:])
    }
}

extension GameActivityTracker {
    func poll(waitForPersistence: Bool = true) async {
        guard !polling else { pollAgain = true
            return
        }
        polling = true
        defer { polling = false }
        pendingLaunches = pendingLaunches.filter { $0.value > now() }
        for (url, bottle) in bottles {
            guard let targets = entries[url], !targets.isEmpty else { continue }
            do {
                let active = try await wineserverProbe(bottle)
                let processes = active ? try await processProbe(bottle) : []
                guard bottles[url] != nil else { continue }
                if queryFailures[url] != nil {
                    queryFailures[url] = nil
                }
                let date = now()
                let runningNames = Set(processes.map { $0.imageName.lowercased() })
                let preferred = preferredNames(in: url, runningNames: runningNames, at: date)
                let matched = GameActivityClock.match(
                    executables: names[url] ?? [:], runningNames: runningNames, preferred: preferred
                )
                let current = Set(targets.filter { matched.contains($0.metadataIdentity) }.map(\.id))
                observe(current: current, targets: targets, bottleURL: url, at: date, serverStopped: !active)
                // UI observations are published before any activity-store reads, locks or writes.
                schedulePersistence(in: url, targets: targets, running: matched, at: date)
            } catch {
                missingSince = missingSince.filter { key, _ in !(runningByBottle[url] ?? []).contains(key) }
                let description = error.localizedDescription
                if queryFailures[url] != description {
                    queryFailures[url] = description
                }
                self.error = description
                // A failed query preserves running state and only releases sampling ownership.
                for entry in targets {
                    try? await sample(entry: entry, running: [], at: now())
                }
            }
        }
        if waitForPersistence {
            await persistenceTask?.value
        }
    }

    private func preferredNames(in url: URL, runningNames: Set<String>, at date: Date) -> [String: String] {
        for (name, var selection) in selections[url] ?? [:] {
            if runningNames.contains(name) {
                selection.observed = true
                selections[url]?[name] = selection
            } else if selection.observed || date.timeIntervalSince(selection.date) > 120 {
                selections[url]?[name] = nil
            }
        }
        return (selections[url] ?? [:]).mapValues(\.identity)
    }

    private func observe(
        current: Set<String>, targets: [LibraryEntry], bottleURL: URL, at date: Date, serverStopped: Bool
    ) {
        let previous = runningByBottle[bottleURL] ?? []
        var retained = current
        var completed: [String: Date] = [:]
        for entry in targets {
            if current.contains(entry.id) {
                missingSince[entry.id] = nil
                pendingLaunches[entry.id] = nil
            } else if previous.contains(entry.id) {
                if serverStopped || missingSince[entry.id] != nil {
                    let ended = missingSince.removeValue(forKey: entry.id) ?? date
                    completed[entry.id] = ended
                    if !entry.isLauncher {
                        pendingCompletions[entry.id] = (entry, ended)
                    }
                } else {
                    missingSince[entry.id] = date
                    retained.insert(entry.id)
                }
            }
        }
        runningByBottle[bottleURL] = retained
        publishObservation(completed: completed)
    }

    private func publishObservation(completed: [String: Date]) {
        let running = runningByBottle.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        guard running != observation.runningEntryIDs || !completed.isEmpty else { return }
        var dates = observation.completedAt
        for (id, date) in completed {
            dates[id] = max(dates[id] ?? date, date)
        }
        observation = Observation(
            runningEntryIDs: running, endedEntryIDs: Set(completed.keys),
            revision: observation.revision &+ 1, completedAt: dates
        )
    }

    private func schedulePersistence(in url: URL, targets: [LibraryEntry], running: Set<String>, at date: Date) {
        pendingSamples[url] = SampleBatch(targets: targets, running: running, date: date)
        guard persistenceTask == nil else { return }
        persistenceTask = Task {
            while let url = self.pendingSamples.keys.first,
                  let batch = self.pendingSamples.removeValue(forKey: url) {
                await self.flushCompletions()
                await self.persistSamples(targets: batch.targets, running: batch.running, at: batch.date)
            }
            self.persistenceTask = nil
        }
    }

    private func persistSamples(targets: [LibraryEntry], running: Set<String>, at date: Date) async {
        for entry in targets where !entry.isLauncher && pendingCompletions[entry.id] == nil {
            do {
                try await sample(entry: entry, running: running, at: date)
                persistenceFailures[entry.id] = nil
            } catch {
                persistenceFailures[entry.id] = error.localizedDescription
            }
        }
        updateError()
    }

    private func flushCompletions() async {
        for (id, completion) in pendingCompletions {
            let entry = completion.entry
            let date = completion.date
            let ownerID = ownerID
            do {
                try await GameActivityStore.shared.perform { store in
                    let owner = try store.acquireOwnership(for: entry, source: .gui, ownerID: ownerID)
                    try store.completeSession(for: entry, at: date, ownerID: ownerID, generation: owner.generation)
                }
                if pendingCompletions[id]?.date == date {
                    pendingCompletions[id] = nil
                }
                persistenceFailures[id] = nil
                let key = TrackingKey(bottle: entry.bottleURL, identity: entry.metadataIdentity)
                generations[key] = nil
                sequences[key] = nil
                clocks[key] = nil
            } catch { persistenceFailures[id] = error.localizedDescription }
        }
        updateError()
    }

    private func updateError() {
        let current = queryFailures.values.first ?? persistenceFailures.values.first
        if error != current {
            error = current
        }
    }

    private func sample(entry: LibraryEntry, running: Set<String>, at date: Date) async throws {
        let key = TrackingKey(bottle: entry.bottleURL, identity: entry.metadataIdentity)
        guard running.contains(entry.metadataIdentity) else {
            if let generation = generations[key] {
                let id = ownerID
                try await GameActivityStore.shared.perform {
                    try $0.releaseOwnership(for: entry, ownerID: id, generation: generation)
                }
                generations[key] = nil
                sequences[key] = nil
            }
            clocks[key] = nil
            return
        }
        do {
            let id = ownerID
            let owner = try await GameActivityStore.shared.perform {
                try $0.acquireOwnership(for: entry, source: .gui, ownerID: id)
            }
            if generations[key] != owner.generation {
                generations[key] = owner.generation
                sequences[key] = 0
                clocks[key] = GameActivityClock()
            }
            let samples = clocks[key, default: GameActivityClock()].sample(
                running: [entry.metadataIdentity],
                at: date,
                uptime: ProcessInfo.processInfo.systemUptime
            )
            let seconds = samples[entry.metadataIdentity] ?? 0
            let sequence = (sequences[key] ?? 0) + 1
            let result = try await GameActivityStore.shared.perform {
                try $0.recordSample(
                    seconds: seconds,
                    at: date,
                    for: entry,
                    ownerID: id,
                    generation: owner.generation,
                    sequence: sequence
                )
            }
            switch result {
            case .applied, .alreadyApplied: sequences[key] = sequence
            case .ownershipChanged:
                clocks[key] = nil
                generations[key] = nil
            }
        } catch GameActivityStore.OwnershipError.heldByLiveOwner {
            clocks[key] = nil
            generations[key] = nil
        }
    }
}
