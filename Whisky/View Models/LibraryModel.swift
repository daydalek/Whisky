// swiftlint:disable file_length
//
//  LibraryModel.swift
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

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import WhiskyKit

/// How the library grid is ordered.
enum LibrarySort: String, CaseIterable, Identifiable {
    case recent
    case name
    case bottle

    var id: String {
        rawValue
    }

    var label: LocalizedStringResource {
        switch self {
        case .recent: "library.sort.recent"
        case .name: "library.sort.name"
        case .bottle: "library.sort.bottle"
        }
    }
}

/// A library entry plus what the grid needs to draw it. `bottleName` and
/// `lastPlayed` are presentation, which is why they live here rather than in
/// ``LibraryEntry``.
struct LibraryRow: Identifiable {
    let item: LibraryEntry
    let bottleName: String?
    let lastPlayed: Date?

    var id: String {
        item.id
    }
}

/// Builds the library and owns what is currently starting or running.
///
/// A view model rather than view state because the running half comes from a
/// ``SteamClientOrchestrator`` per bottle, and those are long-lived objects with
/// their own pollers: the library previously made one per launch and threw it
/// away, so everything it published (the launch phase, the running App IDs, the
/// launch error) went nowhere.
@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var rows: [LibraryRow] = []
    @Published private var hiddenByBottle: [URL: Set<String>] = [:]
    @Published var launchError: String?
    @Published var toast: ToastData?

    /// App IDs with a launch in flight, per bottle.
    @Published private var steamLaunching: [URL: Set<Int>] = [:]
    @Published private var steamPhases: [URL: [Int: SteamClientOrchestrator.Phase]] = [:]
    /// App IDs whose own processes are in the bottle's process list.
    @Published private var steamRunning: [URL: Set<Int>] = [:]
    /// Programs whose launch call has not returned yet.
    @Published private var programLaunching: Set<URL> = []

    var sort: LibrarySort = .recent {
        didSet {
            guard sort != oldValue else { return }
            rows = sorted(rows)
        }
    }

    private var orchestrators: [URL: SteamClientOrchestrator] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var settingsSubscriptions: [AnyCancellable] = []
    private var discoveredEntries: [URL: [LibraryEntry]] = [:]
    private var reloadGeneration = 0

    // MARK: - State

    func isHidden(_ entry: LibraryEntry) -> Bool {
        hiddenByBottle[entry.bottleURL]?.contains(entry.metadataIdentity) == true
    }

    /// What a card should be showing.
    ///
    /// Running is checked before launching because a Steam launch stays in its
    /// grace period for up to two minutes while shaders precompile, which can
    /// outlast the game actually appearing.
    func state(for entry: LibraryEntry) -> LibraryEntryState {
        switch entry.launch {
        case let .program(url):
            programLaunching.contains(url) ? .launching : .idle
        case let .steam(appID):
            if steamRunning[entry.bottleURL]?.contains(appID) == true {
                .running
            } else if steamLaunching[entry.bottleURL]?.contains(appID) == true {
                switch steamPhases[entry.bottleURL]?[appID] {
                case .startingClient: .startingSteam
                case .waitingForClient: .waitingForSteam
                default: .launching
                }
            } else {
                .idle
            }
        }
    }

    // MARK: - Building

    /// Rebuilds every row in one pass.
    ///
    /// Rebuilt whole rather than per card: enumerating Steam walks
    /// `libraryfolders.vdf` and every run log lookup is a plist read, so doing
    /// it inside a card turns scrolling into disk traffic.
    func reload(bottles: [Bottle]) async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let showBottleName = bottles.count > 1
        settingsSubscriptions = bottles.map { bottle in
            bottle.$settings.dropFirst().sink { [weak self, weak bottle] settings in
                guard let self, let bottle else { return }
                // @Published emits before bottle.settings changes: use the new
                // value, not a read of the old settings through the bottle.
                self.updateEntries(in: bottle, settings: settings, showBottleName: showBottleName)
            }
        }
        let available = Set(bottles.map(\.url))
        rows.removeAll { !available.contains($0.item.bottleURL) }
        discoveredEntries = discoveredEntries.filter { available.contains($0.key) }
        // Publish pins immediately; slow filesystem discovery must not delay a
        // newly added pin, or keep a removed one visible.
        for bottle in bottles {
            updateEntries(in: bottle, settings: bottle.settings, showBottleName: showBottleName)
        }
        for bottle in bottles {
            let url = bottle.url
            let discovered: [LibraryEntry]
            do {
                let result = try await Task.detached {
                    let steam = SteamLibrarySource.entries(inBottleAt: url)
                    var folders = try FolderGameLibrary.load(bottleURL: url)
                    let exclusions = SteamLibrary.enumerate(bottleURL: url).map(\.installURL)
                        + [SteamLibrary.detectInstall(bottleURL: url)].compactMap { $0 }
                    let entries = folders.scan(bottleURL: url, steamDirectories: exclusions)
                    return (steam + entries, folders)
                }.value
                guard !Task.isCancelled, generation == reloadGeneration else { return }
                var current = try FolderGameLibrary.load(bottleURL: url)
                if current.roots == result.1.roots,
                   current.assignedFolders == result.1.assignedFolders,
                   current.excludedFolders == result.1.excludedFolders,
                   !current.roots.isEmpty || !current.assignedFolders.isEmpty {
                    current.knownFolders = result.1.knownFolders
                    current.initializedRoots = result.1.initializedRoots
                    current.pendingMetadata.formUnion(result.1.pendingMetadata)
                    try current.save(bottleURL: url)
                }
                discovered = result.0
            } catch {
                launchError = error.localizedDescription
                continue
            }
            guard !Task.isCancelled, generation == reloadGeneration else { return }
            discoveredEntries[url] = discovered
            // Read pins after the await so an earlier scan cannot resurrect a
            // pin removed while discovery was running.
            updateEntries(in: bottle, settings: bottle.settings, showBottleName: showBottleName)
            trackSteam(in: bottle)
        }
    }

    private func updateEntries(in bottle: Bottle, settings: BottleSettings, showBottleName: Bool) {
        let pinned = PinnedLibrarySource.items(inBottleAt: bottle.url, settings: settings)
        let visibility: LibraryVisibility
        do {
            visibility = try LibraryVisibility.load(bottleURL: bottle.url)
        } catch {
            launchError = error.localizedDescription
            return
        }
        hiddenByBottle[bottle.url] = visibility.hiddenIdentities
        let items = LibraryCatalogue.merge([pinned, discoveredEntries[bottle.url] ?? []])
            .filter { visibility.includes($0, showHidden: true) }
        let routed = GameRouting().lastLaunches()
        let updated = items.map { item in
            LibraryRow(
                item: item,
                bottleName: showBottleName ? settings.name : nil,
                lastPlayed: lastPlayed(for: item, routed: routed)
            )
        }
        rows = sorted(rows.filter { $0.item.bottleURL != bottle.url } + updated)
    }

    /// When an entry was last started in Whisky.
    private func lastPlayed(
        for item: LibraryEntry, routed: [Int: Date]
    ) -> Date? {
        switch item.launch {
        case let .program(url):
            RunLogStore.load(for: url.lastPathComponent, in: item.bottleURL)
                .entries.map(\.startTime).max()
        case let .steam(appID):
            routed[appID]
        }
    }

    /// Launchers last whatever the sort is. A storefront client is how you reach
    /// a game, not one of them, and it would otherwise take the top of the grid
    /// on recency because every game launch runs it.
    private func sorted(_ rows: [LibraryRow]) -> [LibraryRow] {
        rows.sorted { first, second in
            if first.item.isLauncher != second.item.isLauncher {
                return second.item.isLauncher
            }
            return switch sort {
            case .recent: byRecency(first, second)
            case .name: byName(first, second)
            case .bottle: byBottle(first, second)
            }
        }
    }

    private func byRecency(_ first: LibraryRow, _ second: LibraryRow) -> Bool {
        switch (first.lastPlayed, second.lastPlayed) {
        case let (lhs?, rhs?): lhs > rhs
        case (_?, nil): true
        case (nil, _?): false
        case (nil, nil): byName(first, second)
        }
    }

    private func byName(_ first: LibraryRow, _ second: LibraryRow) -> Bool {
        first.item.name.localizedStandardCompare(second.item.name) == .orderedAscending
    }

    private func byBottle(_ first: LibraryRow, _ second: LibraryRow) -> Bool {
        let lhs = first.bottleName ?? ""
        let rhs = second.bottleName ?? ""
        guard lhs == rhs else { return lhs.localizedStandardCompare(rhs) == .orderedAscending }
        return byName(first, second)
    }
}

// MARK: - Launching

extension LibraryModel {
    func setHidden(_ hidden: Bool, for item: LibraryEntry) {
        do {
            var visibility = try LibraryVisibility.load(bottleURL: item.bottleURL)
            visibility.setHidden(hidden, for: item)
            try visibility.save(bottleURL: item.bottleURL)
            hiddenByBottle[item.bottleURL] = visibility.hiddenIdentities
        } catch { launchError = error.localizedDescription }
    }

    @discardableResult
    // swiftlint:disable:next function_body_length
    func moveEntry(_ item: LibraryEntry, to targetBottle: Bottle, bottles: [Bottle]) async -> LibraryRow? {
        guard item.bottleURL != targetBottle.url,
              case let .program(url) = item.launch
        else { return nil }
        let wasHidden = isHidden(item)
        do {
            let targetEntry = LibraryEntry(
                id: item.id,
                name: item.name,
                iconURL: item.iconURL,
                artworkURL: item.artworkURL,
                bottleURL: targetBottle.url,
                source: item.source,
                launch: item.launch,
                launcher: item.launcher
            )
            if item.source == .folder {
                try FolderGameLibrary.moveFolder(url, from: item.bottleURL, to: targetBottle.url)
            } else {
                // Program initialization writes defaults when no settings file exists.
                FolderGameLibrary.migrateProgramSettings(for: url, from: item.bottleURL, to: targetBottle.url)
                if let sourceBottle = bottles.first(where: { $0.url == item.bottleURL }) {
                    sourceBottle.settings.pins.removeAll { $0.url == url }
                    if let program = sourceBottle.programs.first(where: { $0.url == url }) {
                        program.pinned = false
                    }
                }
                if !targetBottle.settings.pins.contains(where: { $0.url == url }) {
                    targetBottle.settings.pins.append(PinnedProgram(name: item.name, url: url))
                }
                if let program = targetBottle.programs.first(where: { $0.url == url }) {
                    program.pinned = true
                } else {
                    let program = Program(url: url, bottle: targetBottle)
                    program.pinned = true
                    targetBottle.programs.append(program)
                }
            }

            let sourceStore = GameMetadataStore(directory: item.metadataDirectory)
            let targetStore = GameMetadataStore(directory: targetEntry.metadataDirectory)
            try await sourceStore.copyEntry(
                for: item.metadataIdentity,
                to: targetStore,
                targetIdentity: targetEntry.metadataIdentity
            )
            var visibility = try LibraryVisibility.load(bottleURL: targetBottle.url)
            visibility.setHidden(wasHidden, for: targetEntry)
            try visibility.save(bottleURL: targetBottle.url)
            await reload(bottles: bottles)
            return rows.first { $0.item.bottleURL == targetBottle.url && $0.item.launch == item.launch }
        } catch {
            launchError = error.localizedDescription
            return nil
        }
    }

    func cancelLaunch(_ row: LibraryRow) {
        guard case let .steam(appID) = row.item.launch else { return }
        orchestrators[row.item.bottleURL]?.cancelLaunch(appID: appID)
    }

    func launch(_ row: LibraryRow, bottles: [Bottle]) {
        guard let bottle = bottles.first(where: { $0.url == row.item.bottleURL }) else { return }

        switch row.item.launch {
        case let .program(url):
            if row.item.source == .folder {
                if let executable = folderExecutable(row.item) {
                    launchProgram(at: executable, in: bottle)
                }
            } else {
                launchProgram(at: url, in: bottle)
            }
        case let .steam(appID):
            let games = SteamLibrary.enumerate(bottleURL: bottle.url)
            guard let game = games.first(where: { $0.appId == appID }) else {
                launchError = String(localized: "library.launch.steamGameMissing")
                return
            }
            orchestrator(for: bottle).launch(game)
        }
    }

    func folderExecutable(_ item: LibraryEntry, chooseAgain: Bool = false) -> URL? {
        guard case let .program(folder) = item.launch else { return nil }
        do {
            var library = try FolderGameLibrary.load(bottleURL: item.bottleURL)
            if !chooseAgain, let url = library.executable(for: folder, bottleURL: item.bottleURL),
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            let panel = NSOpenPanel()
            panel.directoryURL = folder
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .data]
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            library.executables[FolderGameLibrary.key(for: folder, bottleURL: item.bottleURL)] =
                FolderGameLibrary.key(for: url, bottleURL: item.bottleURL)
            try library.save(bottleURL: item.bottleURL)
            return url
        } catch {
            launchError = error.localizedDescription
            return nil
        }
    }

    /// Stops a running Steam game. Programs have no per-entry stop: the launch
    /// path returns long before the program exits, so there is nothing tracked
    /// to stop. The bottle's own stop is what reaches those.
    func stop(_ row: LibraryRow, bottles: [Bottle]) {
        guard case let .steam(appID) = row.item.launch,
              let bottle = bottles.first(where: { $0.url == row.item.bottleURL })
        else { return }

        let games = SteamLibrary.enumerate(bottleURL: bottle.url)
        guard let game = games.first(where: { $0.appId == appID }) else { return }
        Task { await orchestrator(for: bottle).stop(game) }
    }

    private func launchProgram(at url: URL, in bottle: Bottle) {
        // Through the bottle's own program list where possible, so the launch
        // picks up that program's overrides rather than only the bottle's.
        guard let program = bottle.programs.first(where: { $0.url == url }) else {
            programLaunching.insert(url)
            Task {
                defer { programLaunching.remove(url) }
                do {
                    try await Program(url: url, bottle: bottle).launch()
                } catch {
                    launchError = error.localizedDescription
                }
            }
            return
        }

        programLaunching.insert(url)
        Telemetry.capture(.firstProgramLaunchAttempted)
        let useTerminal = NSEvent.modifierFlags.contains(.shift)
        Task {
            let result = await program.launchWithUserMode(useTerminal: useTerminal)
            programLaunching.remove(url)
            toast = result.toastData
        }
    }

    /// The orchestrator for a bottle, made once and kept.
    ///
    /// Its `phases` and `runningAppIds` are what the cards read, so it has to
    /// outlive the launch that created it.
    private func orchestrator(for bottle: Bottle) -> SteamClientOrchestrator {
        if let existing = orchestrators[bottle.url] {
            return existing
        }

        let made = SteamClientOrchestrator(bottle: bottle, driver: AppSteamClientDriver(bottle: bottle))
        let url = bottle.url
        made.$phases
            .sink { [weak self] phases in
                self?.steamLaunching[url] = Set(phases.keys)
                self?.steamPhases[url] = phases
            }
            .store(in: &cancellables)
        made.$runningAppIds
            .sink { [weak self] running in
                self?.steamRunning[url] = running
            }
            .store(in: &cancellables)
        made.$launchError
            .compactMap { $0 }
            .sink { [weak self] error in
                self?.launchError = error
            }
            .store(in: &cancellables)

        orchestrators[bottle.url] = made
        return made
    }

    /// Starts (or restarts) running-state polling for a bottle's Steam games.
    private func trackSteam(in bottle: Bottle) {
        let games = SteamLibrary.enumerate(bottleURL: bottle.url)
        guard !games.isEmpty else { return }
        orchestrator(for: bottle).startTracking(games: games)
    }

    /// Stops every poller. Called when the library leaves the screen.
    func stopTracking() {
        settingsSubscriptions.removeAll()
        reloadGeneration += 1
        for orchestrator in orchestrators.values {
            orchestrator.stop()
        }
    }
}
