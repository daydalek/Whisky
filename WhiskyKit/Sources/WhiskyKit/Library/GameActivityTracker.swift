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

/// Kept for the application's lifetime so navigating away from the library keeps counting.
@MainActor
public final class GameActivityTracker: ObservableObject {
    public static let shared = GameActivityTracker()
    @Published public private(set) var error: String?
    @Published public private(set) var lastUpdatedEntryID: String?
    private var cancellables = Set<AnyCancellable>()

    public init(store: GameActivityStore? = .shared, entryID: String? = nil) {
        NotificationCenter.default.publisher(for: GameActivityStore.didUpdateNotification, object: store)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self else { return }
                guard let id = notification.userInfo?[GameActivityStore.entryIDKey] as? String else { return }
                if let entryID, id != entryID { return }
                self.lastUpdatedEntryID = id
                self.error = nil
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
    var wineserverProbe: @MainActor (Bottle) async -> Bool = { await Wine.isWineserverRunning(for: $0) }
    var processProbe: @MainActor (Bottle) async throws -> [WineProcess] = { try await Wine.listProcesses(for: $0) }

    /// A library launch disambiguates games that share an executable filename.
    public func track(_ entry: LibraryEntry, executable: URL, bottle: Bottle) {
        bottles[bottle.url] = bottle
        if entries[bottle.url]?.contains(where: { $0.metadataIdentity == entry.metadataIdentity }) != true {
            entries[bottle.url, default: []].append(entry)
        }
        let name = executable.lastPathComponent.lowercased()
        names[bottle.url, default: [:]][entry.metadataIdentity] = [name]
        select(entry)
    }

    public func select(_ entry: LibraryEntry) {
        for name in names[entry.bottleURL]?[entry.metadataIdentity] ?? [] {
            selections[entry.bottleURL, default: [:]][name] = Selection(
                identity: entry.metadataIdentity, date: Date()
            )
        }
        start()
    }

    public func configure(entries: [LibraryEntry], bottle: Bottle) async {
        self.entries[bottle.url] = entries.filter { !$0.isLauncher }
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
                        SteamLibrary.executableNames(under: $0.installURL)
                    } ?? []
                case let .program(program):
                    let executable = entry.source == .folder
                        ? folders?.executable(for: program, bottleURL: url) : program
                    executables = executable.map { Set([$0.lastPathComponent.lowercased()]) } ?? []
                }
                return (entry.metadataIdentity, executables)
            })
        }.value
        start()
    }

    private func start() {
        if automaticallyPolls, task == nil {
            task = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.poll()
                    try? await Task.sleep(for: .seconds(10))
                }
            }
        }
    }

    public func retainBottles(_ urls: Set<URL>) {
        entries = entries.filter { urls.contains($0.key) }
        bottles = bottles.filter { urls.contains($0.key) }
        names = names.filter { urls.contains($0.key) }
        clocks = clocks.filter { urls.contains($0.key.bottle) }
        generations = generations.filter { urls.contains($0.key.bottle) }
        sequences = sequences.filter { urls.contains($0.key.bottle) }
        selections = selections.filter { urls.contains($0.key) }
    }

    func poll() async {
        for (url, bottle) in bottles {
            // Skip bottles that have no configured library targets
            guard let targets = entries[url], !targets.isEmpty else {
                continue
            }

            // Only poll bottles whose wineserver is actively running
            guard await wineserverProbe(bottle) else {
                await releaseOwnership(for: targets)
                clocks = clocks.filter { $0.key.bottle != url }
                continue
            }

            do {
                let processes = try await processProbe(bottle)
                let runningNames = Set(processes.map { $0.imageName.lowercased() })
                guard bottles[url] != nil else { continue }
                let now = Date()
                for (name, var selection) in selections[url] ?? [:] {
                    if runningNames.contains(name) {
                        selection.observed = true
                        selections[url]?[name] = selection
                    } else if selection.observed || now.timeIntervalSince(selection.date) > 120 {
                        selections[url]?[name] = nil
                    }
                }
                let preferred = (selections[url] ?? [:]).mapValues(\.identity)
                let running = GameActivityClock.match(
                    executables: names[url] ?? [:], runningNames: runningNames, preferred: preferred
                )
                for entry in targets {
                    try await sample(entry: entry, running: running, at: now)
                }
                error = nil
            } catch {
                await releaseOwnership(for: targets)
                clocks = clocks.filter { $0.key.bottle != url }
                self.error = error.localizedDescription
            }
        }
    }

    private func releaseOwnership(for targets: [LibraryEntry]) async {
        for entry in targets {
            try? await sample(entry: entry, running: [], at: Date())
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
