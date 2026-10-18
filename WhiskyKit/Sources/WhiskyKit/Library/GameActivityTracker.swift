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
    private var entries: [URL: [LibraryEntry]] = [:]
    private var bottles: [URL: Bottle] = [:]
    private var names: [URL: [String: Set<String>]] = [:]
    private var clocks: [URL: GameActivityClock] = [:]
    private var task: Task<Void, Never>?
    private struct Selection {
        let identity: String
        let date: Date
        var observed = false
    }

    private var selections: [URL: [String: Selection]] = [:]

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
        if task == nil {
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
        clocks = clocks.filter { urls.contains($0.key) }
        selections = selections.filter { urls.contains($0.key) }
    }

    private func poll() async {
        for (url, bottle) in bottles {
            guard await Wine.isWineserverRunning(for: bottle) else {
                clocks[url] = GameActivityClock()
                continue
            }
            do {
                let processes = try await Wine.listProcesses(for: bottle)
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
                var clock = clocks[url] ?? GameActivityClock()
                let samples = clock.sample(running: running, at: now)
                clocks[url] = clock
                for entry in entries[url] ?? [] {
                    if let seconds = samples[entry.metadataIdentity] {
                        try GameActivityStore.shared.record(seconds, at: now, for: entry)
                    }
                }
                error = nil
            } catch {
                clocks[url] = GameActivityClock()
                self.error = error.localizedDescription
            }
        }
    }
}
