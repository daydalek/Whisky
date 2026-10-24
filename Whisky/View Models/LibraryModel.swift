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

import Combine
import Foundation
import WhiskyCore
import WhiskyKit

extension LibrarySort {
    var label: LocalizedStringResource {
        switch self {
        case .recent: "library.sort.recent"
        case .name: "library.sort.name"
        case .bottle: "library.sort.bottle"
        }
    }
}

/// A library entry plus what the grid needs to draw it. `bottleName` and
/// `lastSessionEndedAt` are presentation, which is why they live here rather than in
/// ``LibraryEntry``.
struct LibraryRow: Identifiable, Equatable, LibrarySortableRow {
    let item: LibraryEntry
    let bottleName: String?
    var lastSessionEndedAt: Date?
    var activity = GameActivity()

    var id: String {
        item.id
    }
}

/// Builds UI rows and translates shared runtime events into Combine observation.
@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var rows: [LibraryRow] = [] {
        didSet {
            let ids = Set(rows.map(\.id))
            if ids != catalogueIDs {
                catalogueIDs = ids
                catalogueRevision &+= 1
                NotificationCenter.default.post(name: LibrarySidebarCounts.didChange, object: nil)
            }
        }
    }

    private var catalogueIDs: Set<String> = []
    @Published private(set) var catalogueRevision: UInt64 = 0
    @Published private var hiddenByBottle: [URL: Set<String>] = [:]
    @Published var launchError: String?
    @Published var toast: ToastData?

    @Published private var runtimeState = LibraryRuntimeState()
    private let runtime: any LibraryRuntime
    private let content: any LibraryContentProviding
    private var runtimeEventsTask: Task<Void, Never>?
    private var activityRefreshGeneration = 0
    private var pendingActivityIDs: Set<String> = []
    @Published private(set) var completionRevision: UInt64 = 0
    private(set) var completedEntryIDs: Set<String> = []
    private let executablePicker: any ExecutablePicker
    private let terminalLaunchRequested: @MainActor () -> Bool
    private var executableSelections: [String: Task<URL?, any Error>] = [:]

    init(
        runtime: any LibraryRuntime, content: any LibraryContentProviding, executablePicker: any ExecutablePicker,
        terminalLaunchRequested: @escaping @MainActor () -> Bool
    ) {
        self.runtime = runtime
        self.content = content
        self.runtimeState = runtime.state
        self.executablePicker = executablePicker
        self.terminalLaunchRequested = terminalLaunchRequested
        let events = runtime.events()
        runtimeEventsTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.consume(event)
            }
        }
    }

    private func consume(_ event: LibraryRuntimeEvent) {
        switch event {
        case let .state(updated):
            let changed = updated.observation != runtimeState.observation
            runtimeState = updated
            let observation = updated.observation
            guard changed, !observation.endedEntryIDs.isEmpty,
                  UserDefaults.standard.object(forKey: "libraryRefreshAfterExit") as? Bool ?? true
            else { return }
            applyCompletions(observation.completedAt, entryIDs: observation.endedEntryIDs)
            Task { await self.refreshActivity(entryIDs: observation.endedEntryIDs) }
        case let .launchResult(id, result):
            if let error = result.errorDescription, !runtimeState.launch.runningEntryIDs.contains(id) {
                launchError = error
            }
            toast = result.toastData
        case let .failure(failure):
            switch failure {
            case let .launchTimedOut(_, detail):
                launchError = String(localized: "library.launch.timeout") + (detail.map { "\n" + $0 } ?? "")
            case .unavailable: launchError = CocoaError(.fileNoSuchFile).localizedDescription
            case let .driver(message): launchError = message
            }
        }
    }

    deinit {
        runtimeEventsTask?.cancel()
        for task in executableSelections.values {
            task.cancel()
        }
    }

    /// Refresh only personal records. Artwork, catalogue discovery and network matching stay cached.
    func refreshActivity(entryIDs: Set<String>? = nil) async {
        activityRefreshGeneration += 1
        let generation = activityRefreshGeneration
        pendingActivityIDs.formUnion(entryIDs ?? Set(rows.map(\.id)))
        let entries = rows.filter { pendingActivityIDs.contains($0.id) }.map(\.item)
        guard let records = try? await content.activities(for: entries),
              !Task.isCancelled, generation == activityRefreshGeneration
        else { return }
        pendingActivityIDs.removeAll()
        var updated = rows
        for index in updated.indices {
            if let activity = records[updated[index].id] {
                let current = activityWithCompletions(activity, for: updated[index].item)
                updated[index].activity = current
                updated[index].lastSessionEndedAt = current.lastSessionEndedAt
            }
        }
        let ordered = sorted(updated)
        if ordered != rows {
            rows = ordered
        }
    }

    var sort: LibrarySort = .recent {
        didSet {
            guard sort != oldValue, !presentationUpdate else { return }
            rows = sorted(rows)
        }
    }

    /// Cover and card views keep storefront clients after the games.
    /// Timeline views follow the selected ordering across all entries.
    var groupsLaunchers = true {
        didSet {
            guard groupsLaunchers != oldValue, !presentationUpdate else { return }
            rows = sorted(rows)
        }
    }

    private var presentationUpdate = false

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
        runtimeState.launch.state(for: entry)
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
        settingsSubscriptions = observeSettings(in: bottles, showBottleName: showBottleName)
        let available = Set(bottles.map(\.url))
        runtime.retainContainers(available)
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
                let result = try await content.discover(in: url)
                guard !Task.isCancelled, generation == reloadGeneration else { return }
                try content.commit(result)
                discovered = result.entries
            } catch {
                launchError = error.localizedDescription
                continue
            }
            guard !Task.isCancelled, generation == reloadGeneration else { return }
            discoveredEntries[url] = discovered
            // Read pins after the await so an earlier scan cannot resurrect a
            // pin removed while discovery was running.
            updateEntries(in: bottle, settings: bottle.settings, showBottleName: showBottleName)
            await configureRuntime(in: bottle)
        }
    }

    private func configureRuntime(in bottle: Bottle) async {
        await runtime.configure(
            entries: rows.filter { $0.item.bottleURL == bottle.url }.map(\.item), containerURL: bottle.url
        )
    }

    private func updateEntries(in bottle: Bottle, settings: BottleSettings, showBottleName: Bool) {
        let pinned = PinnedLibrarySource.items(inBottleAt: bottle.url, settings: settings)
        let visibility: LibraryVisibility
        do {
            visibility = try content.visibility(in: bottle.url)
        } catch {
            launchError = error.localizedDescription
            return
        }
        hiddenByBottle[bottle.url] = visibility.hiddenIdentities
        let items = LibraryCatalogue.merge([pinned, discoveredEntries[bottle.url] ?? []])
            .filter { visibility.includes($0, showHidden: true) }
        let updated = items.map { item in
            let activity = activityWithCompletions(
                (try? content.activity(for: item)) ?? GameActivity(),
                for: item
            )
            return LibraryRow(
                item: item,
                bottleName: showBottleName ? settings.name : nil,
                lastSessionEndedAt: activity.lastSessionEndedAt,
                activity: activity
            )
        }
        rows = sorted(rows.filter { $0.item.bottleURL != bottle.url } + updated)
    }

    /// Presentation may group launchers after games; timelines use a single order.
    private func sorted(_ rows: [LibraryRow]) -> [LibraryRow] {
        LibraryOrdering.sorted(rows, by: sort, groupsLaunchers: groupsLaunchers)
    }
}

// MARK: - Launching

extension LibraryModel {
    func setHidden(_ hidden: Bool, for item: LibraryEntry) {
        do {
            let visibility = try content.setHidden(hidden, for: item)
            hiddenByBottle[item.bottleURL] = visibility.hiddenIdentities
            NotificationCenter.default.post(name: LibrarySidebarCounts.didChange, object: nil)
        } catch { launchError = error.localizedDescription }
    }

    @discardableResult
    func moveEntry(_ item: LibraryEntry, to targetBottle: Bottle, bottles: [Bottle]) async -> LibraryRow? {
        guard item.bottleURL != targetBottle.url, case .program = item.launch else { return nil }
        do {
            _ = try await content.move(item, to: targetBottle.url, hidden: isHidden(item))
            await reload(bottles: bottles)
            return rows.first { $0.item.bottleURL == targetBottle.url && $0.item.launch == item.launch }
        } catch {
            launchError = error.localizedDescription
            return nil
        }
    }

    func cancelLaunch(_ row: LibraryRow) {
        runtime.cancelLaunch(for: row.item)
    }

    func launch(_ row: LibraryRow, bottles: [Bottle]) {
        guard bottles.contains(where: { $0.url == row.item.bottleURL }) else { return }
        let mode: LibraryLaunchRequest.Mode = terminalLaunchRequested() ? .terminal : .standard
        if case .program = row.item.launch, row.item.source == .folder {
            Task {
                guard let executable = await folderExecutable(row.item),
                      rows.contains(where: { $0.id == row.id && $0.item.bottleURL == row.item.bottleURL })
                else { return }
                launch(LibraryLaunchRequest(entry: row.item, executableURL: executable, mode: mode))
            }
        } else {
            let requestedMode: LibraryLaunchRequest.Mode = if case .steam = row.item.launch {
                .standard
            } else {
                mode
            }
            launch(LibraryLaunchRequest(entry: row.item, mode: requestedMode))
        }
    }

    private func launch(_ request: LibraryLaunchRequest) {
        if case .program = request.entry.launch {
            Telemetry.capture(.firstProgramLaunchAttempted)
        }
        runtime.launch(request)
    }

    func folderExecutable(_ item: LibraryEntry, chooseAgain: Bool = false) async -> URL? {
        do {
            if let pending = executableSelections[item.id] {
                return try await pending.value
            }
            let picker = executablePicker
            let task = Task {
                try await FolderGameLibrary.resolveExecutable(for: item, chooseAgain: chooseAgain, picker: picker)
            }
            executableSelections[item.id] = task
            defer { executableSelections[item.id] = nil }
            return try await task.value
        } catch {
            launchError = error.localizedDescription
            return nil
        }
    }

    func stop(_ row: LibraryRow, bottles: [Bottle]) {
        guard bottles.contains(where: { $0.url == row.item.bottleURL }) else { return }
        Task { await runtime.stop(row.item) }
    }

    /// Stops UI pollers while application-scoped activity tracking continues.
    func stopTracking() {
        settingsSubscriptions.removeAll()
        reloadGeneration += 1
        runtime.stopTracking()
    }
}

private extension LibraryModel {
    private func activityWithCompletions(_ record: GameActivity, for item: LibraryEntry) -> GameActivity {
        var activity = record
        if let observed = runtimeState.observation.completedAt[item.id] {
            activity.lastSessionEndedAt = max(activity.lastSessionEndedAt ?? observed, observed)
        }
        return activity
    }
}

extension LibraryModel {
    private func observeSettings(in bottles: [Bottle], showBottleName: Bool) -> [AnyCancellable] {
        bottles.map { bottle in
            let updates = bottle.$settings.removeDuplicates { lhs, rhs in
                lhs.name == rhs.name && lhs.pins == rhs.pins
            }
            return updates.dropFirst().sink { [weak self, weak bottle] settings in
                guard let self, let bottle else { return }
                self.updateEntries(in: bottle, settings: settings, showBottleName: showBottleName)
            }
        }
    }

    /// A presentation change reuses loaded activity and sorts once.
    func configurePresentation(sort: LibrarySort, groupsLaunchers: Bool) {
        guard self.sort != sort || self.groupsLaunchers != groupsLaunchers else { return }
        presentationUpdate = true
        self.sort = sort
        self.groupsLaunchers = groupsLaunchers
        presentationUpdate = false
        rows = sorted(rows)
    }

    private func applyCompletions(_ dates: [String: Date], entryIDs: Set<String>) {
        var updated = rows
        for index in updated.indices where entryIDs.contains(updated[index].id) {
            updated[index].lastSessionEndedAt = dates[updated[index].id]
            updated[index].activity.lastSessionEndedAt = dates[updated[index].id]
        }
        let ordered = sorted(updated)
        if ordered != rows {
            rows = ordered
        }
        completedEntryIDs = entryIDs
        completionRevision &+= 1
    }
}
