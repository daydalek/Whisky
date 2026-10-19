// swiftlint:disable file_length
//
//  LibraryView.swift
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
import SwiftUI
import UniformTypeIdentifiers
import WhiskyKit

enum LibraryDisplayMode: String, CaseIterable, Identifiable {
    case covers
    case timeline
    case classic

    var id: String { rawValue }
}

// swiftlint:disable type_body_length
/// Everything worth launching, across every bottle, most recently played first.
///
/// This is the home screen because it is the thing people open Whisky to do. A
/// bottle is a Wine prefix, which is an implementation detail of running a
/// Windows program on a Mac, and it only earns space on screen once there is
/// more than one of them.
///
/// Entries come from ``LibraryCatalogue``, so Steam games sit beside pinned
/// programs and a future launcher needs no change here.
struct LibraryView: View {
    @EnvironmentObject var bottleVM: BottleVM
    @Binding var selectedBottle: URL?
    /// Toggled by the toolbar's refresh button. Folded into the reload trigger
    /// because the bottle list is unchanged by a refresh, so watching only that
    /// left the button spinning without rebuilding anything.
    @Binding var refresh: Bool
    @Binding var coverMode: Bool

    @AppStorage("libraryDisplayMode") private var displayMode: LibraryDisplayMode = .covers
    @AppStorage("libraryShowHiddenGames") private var showHiddenGames = false
    @AppStorage("librarySort") private var sort: LibrarySort = .recent
    @AppStorage("librarySingleLineTitles") private var singleLineTitles = false
    @AppStorage("libraryMixedCoverLayout") private var mixedCoverLayout = true

    @StateObject private var model = LibraryModel()
    @State private var search: String = ""
    @State private var detailRow: LibraryRow?
    @State private var settingsProgram: Program?
    @State private var steamSettingsRow: LibraryRow?
    @State private var metadata: [String: GameMetadata] = [:]
    @State private var metadataRevision = 0
    @State private var coverAspectRatios: [String: Double] = [:]
    @State private var metadataError: String?
    @State private var showScanSettings = false
    @State private var manualSync = false
    @State private var syncing = false
    @State private var ambientController = LibraryAmbientController()
    @AppStorage("libraryMetadataEnabledSources") private var enabledSourceIDs = "bangumi,vndb,steam,ymgal"

    private var bottles: [Bottle] {
        bottleVM.bottles.filter(\.isAvailable)
    }

    private var visible: [LibraryRow] {
        let rows = model.rows.filter { showHiddenGames || !model.isHidden($0.item) }
        guard !search.isEmpty else { return rows }
        return rows.filter { row in
            row.item.name.localizedCaseInsensitiveContains(search)
                || metadata[row.id]?.matchingTitles.contains {
                    $0.localizedCaseInsensitiveContains(search)
                } == true
        }
    }

    /// Pin changes are observed by the model without a filesystem rescan.
    private var reloadTrigger: String {
        (bottles.map(\.url.path) + ["\(refresh)"]).joined(separator: "\u{1F}")
    }

    var body: some View {
        Group {
            if model.rows.isEmpty {
                emptyState
            } else if visible.isEmpty {
                filteredEmptyState
            } else {
                grid
            }
        }
        .background {
            LibraryAmbientBackdrop(controller: ambientController)
        }
        .navigationTitle("library.title")
        .searchable(text: $search, prompt: Text("library.search"))
        .toolbar { sortMenu }
        .toast($model.toast)
        .task(id: reloadTrigger) {
            await model.reload(bottles: bottles)
        }
        .task(id: model.rows.map(\.id).joined(separator: "\u{1F}") + "\(metadataRevision)") {
            await loadMetadata()
        }
        .sheet(item: $detailRow) { row in
            LibraryGameSheet(
                item: row.item,
                bottles: bottles,
                launch: { model.launch(row, bottles: bottles) },
                moveBottle: { targetBottle in
                    Task {
                        if let moved = await model.moveEntry(row.item, to: targetBottle, bottles: bottles) {
                            detailRow = moved
                        }
                    }
                },
                didSave: { metadataRevision += 1 }
            )
        }
        .sheet(isPresented: $showScanSettings) {
            LibraryFolderSettings(bottles: bottles, initialBottleURL: selectedBottle) { refresh.toggle() }
        }
        .sheet(item: $settingsProgram) { program in
            VStack(spacing: 0) {
                HStack {
                    Text(program.name).font(.headline)
                    Spacer()
                    Button("button.ok") { settingsProgram = nil }
                }.padding()
                ProgramView(program: program)
            }
            .frame(minWidth: 640, minHeight: 560)
        }
        .sheet(item: $steamSettingsRow) { row in
            if let bottle = bottles.first(where: { $0.url == row.item.bottleURL }),
               case let .steam(appID) = row.item.launch {
                LibrarySteamSettingsSheet(bottle: bottle, appID: appID, title: row.item.name) {
                    steamSettingsRow = nil
                    selectedBottle = row.item.bottleURL
                }
            }
        }
        .onChange(of: sort, initial: true) {
            model.sort = sort
        }
        .onChange(of: displayMode, initial: true) {
            coverMode = displayMode != .classic
        }
        .onChange(of: coverMode) {
            if !coverMode, displayMode != .classic {
                displayMode = .classic
            } else if coverMode, displayMode == .classic {
                displayMode = .covers
            }
        }
        .onDisappear {
            model.stopTracking()
        }
        .alert(
            Text(model.launchError == nil ? "library.metadata.error" : "library.launch.failed"),
            isPresented: Binding(
                get: { model.launchError != nil || metadataError != nil },
                set: {
                    if !$0 {
                        model.launchError = nil
                        metadataError = nil
                    }
                }
            )
        ) {
            Button("button.ok") { model.launchError = nil
                metadataError = nil
            }
        } message: {
            Text(model.launchError ?? metadataError ?? "")
        }
    }

    @ToolbarContentBuilder
    private var sortMenu: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Picker("library.view.covers", selection: $displayMode) {
                Image(systemName: "books.vertical")
                    .help(LocalizedStringKey("library.view.switchToCovers"))
                    .tag(LibraryDisplayMode.covers)
                Image(systemName: "book.pages")
                    .help(LocalizedStringKey("library.view.switchToTimeline"))
                    .tag(LibraryDisplayMode.timeline)
                Image(systemName: "rectangle.grid.2x2")
                    .help(LocalizedStringKey("library.view.switchToClassic"))
                    .tag(LibraryDisplayMode.classic)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("library.view.toggle")
        }
        ToolbarItem(placement: .automatic) {
            Menu {
                Picker("library.sort", selection: $sort) {
                    ForEach(LibrarySort.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.inline)
                if displayMode == .covers {
                    Divider()
                    Toggle("settings.library.mixedCoverLayout", isOn: $mixedCoverLayout)
                    Toggle("settings.library.singleLineTitles", isOn: $singleLineTitles)
                }
                Divider()
                Button {
                    syncing = true
                    Task {
                        await model.reload(bottles: bottles)
                        manualSync = true
                        metadataRevision += 1
                    }
                } label: {
                    Label("library.sync.manual", systemImage: "text.magnifyingglass")
                }
                .disabled(syncing)
                .accessibilityIdentifier("library.scanAndSync")

                Button { showScanSettings = true } label: {
                    Label("library.scan.folders", systemImage: "folder.badge.plus")
                }

                Toggle(isOn: $showHiddenGames) {
                    Label("library.visibility.showAll", systemImage: showHiddenGames ? "eye" : "eye.slash")
                }
                .accessibilityIdentifier("library.visibility.toggle")

                Divider()
                Button {
                    bottleVM.loadBottles()
                    refresh.toggle()
                } label: {
                    Label("button.refresh", systemImage: "arrow.triangle.2.circlepath")
                }
            } label: {
                Label("library.sort", systemImage: "ellipsis.circle")
            }
            .help("library.sort.help")
            .accessibilityIdentifier("library.sort")
        }
    }

    @ViewBuilder
    private var grid: some View {
        switch displayMode {
        case .timeline:
            timelineView
        case .covers:
            if mixedCoverLayout {
                mixedCoverGrid
            } else {
                uniformGrid
            }
        case .classic:
            uniformGrid
        }
    }

    private var timelineView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(visible) { row in
                    LibraryTimelineRow(
                        item: row.item,
                        metadata: metadata[row.id],
                        bottleName: row.bottleName,
                        lastPlayed: row.lastPlayed,
                        state: model.state(for: row.item),
                        details: { detailRow = row },
                        launch: { model.launch(row, bottles: bottles) },
                        coverAspectRatio: coverAspectRatios[row.id],
                        coverAspectRatioDidLoad: { aspect in
                            if coverAspectRatios[row.id] != aspect { coverAspectRatios[row.id] = aspect }
                        },
                        onHoverCoverChanged: { hovering, url, dir in
                            updateHoveredCover(hovering: hovering, row: row, url: url, directory: dir)
                        },
                        coverRevision: metadataRevision,
                        menuContent: { menu(for: row) }
                    )
                    .modifier(LibraryHiddenBadge(hidden: model.isHidden(row.item)))
                    .contextMenu { menu(for: row) }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
    }

    private var mixedCoverGrid: some View {
        GeometryReader { geometry in
            let entries = visible
            let layout = LibraryCoverGrid(
                width: max(geometry.size.width - 36, 1),
                landscape: entries.map { (coverAspectRatios[$0.id] ?? 0) > 1 }
            )
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(layout.rows.enumerated()), id: \.offset) { _, indices in
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(indices, id: \.self) { index in
                                let row = entries[index]
                                LibraryCoverCard(
                                    item: row.item, metadata: metadata[row.id],
                                    bottleName: row.bottleName, state: model.state(for: row.item),
                                    details: { detailRow = row }, launch: { model.launch(row, bottles: bottles) },
                                    coverHeight: layout.coverHeight,
                                    adaptToFrame: true,
                                    coverAspectRatioDidLoad: { aspect in
                                        if coverAspectRatios[row.id] != aspect { coverAspectRatios[row.id] = aspect }
                                    },
                                    onHoverCoverChanged: { hovering, url, dir in
                                        updateHoveredCover(hovering: hovering, row: row, url: url, directory: dir)
                                    },
                                    coverRevision: metadataRevision
                                )
                                .frame(width: layout.width(for: index))
                                .modifier(LibraryHiddenBadge(hidden: model.isHidden(row.item)))
                                .contextMenu { menu(for: row) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
        }
    }

    private var uniformGrid: some View {
        ScrollView {
            LazyVGrid(
                // 180 rather than 220 so two columns fit at the window's own
                // minimum width, where the sidebar leaves about 330pt: one
                // column of landscape cards is a list with wasted space.
                columns: [GridItem(.adaptive(
                    minimum: coverMode ? 140 : 180, maximum: coverMode ? 200 : 320
                ), spacing: coverMode ? 12 : 14, alignment: .top)],
                alignment: .leading,
                spacing: coverMode ? 12 : 14
            ) {
                ForEach(visible) { row in
                    Group {
                        if coverMode {
                            LibraryCoverCard(
                                item: row.item, metadata: metadata[row.id],
                                bottleName: row.bottleName,
                                state: model.state(for: row.item), details: { detailRow = row },
                                launch: { model.launch(row, bottles: bottles) },
                                onHoverCoverChanged: { hovering, url, dir in
                                    updateHoveredCover(hovering: hovering, row: row, url: url, directory: dir)
                                },
                                coverRevision: metadataRevision
                            )
                        } else {
                            LibraryCard(
                                item: row.item,
                                bottleName: row.bottleName,
                                lastPlayed: row.lastPlayed,
                                state: model.state(for: row.item),
                                launch: { model.launch(row, bottles: bottles) }
                            )
                        }
                    }
                    .modifier(LibraryHiddenBadge(hidden: model.isHidden(row.item)))
                    .contextMenu { menu(for: row) }
                }
            }
            .padding(18)
        }
    }

    private func updateHoveredCover(hovering: Bool, row: LibraryRow, url: URL?, directory: URL) {
        ambientController.updateHover(
            hovering: hovering,
            id: row.id,
            url: url ?? metadata[row.id]?.coverURL,
            directory: directory
        )
    }

    @ViewBuilder
    // swiftlint:disable:next function_body_length
    private func menu(for row: LibraryRow) -> some View {
        Button("button.run") { model.launch(row, bottles: bottles) }
            .disabled(model.state(for: row.item).isPending)
        if case .steam = row.item.launch, model.state(for: row.item).isPending {
            Button("library.steam.cancelWaiting") { model.cancelLaunch(row) }
        }
        if model.state(for: row.item) == .running {
            Button("library.card.stop") { model.stop(row, bottles: bottles) }
        }
        Divider()
        Button {
            model.setHidden(!model.isHidden(row.item), for: row.item)
        } label: {
            Label(
                model.isHidden(row.item) ? "library.visibility.unhide" : "library.visibility.hide",
                systemImage: model.isHidden(row.item) ? "eye" : "eye.slash"
            )
        }
        if !row.item.isLauncher {
            Button("library.metadata.details") { detailRow = row }
        }
        if case let .program(url) = row.item.launch {
            if bottles.count > 1 {
                Menu("library.bottle.target") {
                    Picker("library.bottle.target", selection: Binding(
                        get: { row.item.bottleURL },
                        set: { targetURL in
                            guard let target = bottles.first(where: { $0.url == targetURL }) else { return }
                            Task { await model.moveEntry(row.item, to: target, bottles: bottles) }
                        }
                    )) {
                        ForEach(bottles, id: \.url) { bottle in
                            Text(bottle.settings.name).tag(bottle.url)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            if row.item.source == .folder {
                Button("library.scan.executable") { _ = model.folderExecutable(row.item, chooseAgain: true) }
            }
            Button("library.program.settings") {
                guard let bottle = bottles.first(where: { $0.url == row.item.bottleURL }),
                      let executable = row.item.source == .folder ? model.folderExecutable(row.item) : url
                else { return }
                settingsProgram = bottle.programs.first(where: { $0.url == executable })
                    ?? Program(url: executable, bottle: bottle)
            }
            Button("button.showInFinder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            if row.item.source != .folder {
                Button("library.card.unpin", role: .destructive) { unpin(url, in: row.item.bottleURL) }
            }
        } else if case .steam = row.item.launch {
            Button("library.program.settings") { steamSettingsRow = row }
        }
        // Shared runtime configuration remains in the bottle, not in a game's sheet.
        Button("library.card.configure") {
            selectedBottle = row.item.bottleURL
        }
    }

    private func unpin(_ url: URL, in bottleURL: URL) {
        guard let bottle = bottles.first(where: { $0.url == bottleURL }) else { return }
        bottle.settings.pins.removeAll { $0.url == url }
        if let program = bottle.programs.first(where: { $0.url == url }) {
            program.pinned = false
        }
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func loadMetadata() async {
        syncing = true
        let requested = manualSync
        manualSync = false
        defer { syncing = false }
        var loaded: [String: GameMetadata] = [:]
        var stores: [URL: GameMetadataStore] = [:]
        var libraries: [URL: FolderGameLibrary] = [:]
        let sources = GameMetadataSource.allCases.filter {
            enabledSourceIDs.split(separator: ",").contains(Substring($0.rawValue))
                && $0 != .hikarinagi
        }
        let providers = sources.map { PublicGameMetadataProvider(source: $0) }
        for row in model.rows {
            guard !Task.isCancelled else { return }
            do {
                let directory = row.item.metadataDirectory
                let store = stores[directory] ?? {
                    let created = GameMetadataStore(directory: directory)
                    stores[directory] = created
                    return created
                }()
                loaded[row.id] = try await store.load(for: row.item.metadataIdentity)
                let aspect = try await store.coverAspectRatio(
                    for: row.item.metadataIdentity, metadataCoverURL: loaded[row.id]?.coverURL
                )
                if !Task.isCancelled {
                    coverAspectRatios[row.id] = aspect
                    metadata[row.id] = loaded[row.id]
                }
                if model.isHidden(row.item) || NetworkSettings.isOffline { continue }
                let bottleURL = row.item.bottleURL
                let library = try libraries[bottleURL] ?? {
                    let loadedLibrary = try FolderGameLibrary.load(bottleURL: bottleURL)
                    libraries[bottleURL] = loadedLibrary
                    return loadedLibrary
                }()
                let folderKey: String? = {
                    guard row.item.source == .folder, case let .program(folder) = row.item.launch else { return nil }
                    return FolderGameLibrary.key(for: folder, bottleURL: bottleURL)
                }()
                if loaded[row.id] == nil, let folderKey,
                   requested || (library.automaticMetadata && library.pendingMetadata.contains(folderKey)),
                   try await store.allowsAutomaticMatch(for: row.item.metadataIdentity) {
                    if !providers.isEmpty {
                        let query = FolderGameMatching.query(row.item.name)
                        let outcome = await GameMetadataSearch.automaticMatch(query, providers: providers)
                        try Task.checkCancellation()
                        if !outcome.allProvidersFailed {
                            try completeInitialMatch(folderKey, bottleURL: bottleURL, libraries: &libraries)
                        }
                        if let candidate = outcome.candidate {
                            let details = try await PublicGameMetadataProvider(source: candidate.source)
                                .details(for: candidate).usingLibraryTitle(row.item.name)
                            try Task.checkCancellation()
                            try await store.saveAutomatic(details, for: row.item.metadataIdentity)
                            loaded[row.id] = try await store.load(for: row.item.metadataIdentity)
                            if let cover = details.coverURL {
                                try? await store.cacheCover(from: cover)
                            }
                            let aspect = try await store.coverAspectRatio(
                                for: row.item.metadataIdentity, metadataCoverURL: loaded[row.id]?.coverURL
                            )
                            if !Task.isCancelled {
                                coverAspectRatios[row.id] = aspect
                                metadata[row.id] = loaded[row.id]
                            }
                        }
                    }
                } else if let folderKey, library.pendingMetadata.contains(folderKey) {
                    try completeInitialMatch(folderKey, bottleURL: bottleURL, libraries: &libraries)
                }
            } catch is CancellationError {
                return
            } catch {
                // Do not replace corrupt metadata with defaults or affect launching.
                metadataError = error.localizedDescription
            }
        }
        if !Task.isCancelled {
            metadata = loaded
        }
    }

    private func completeInitialMatch(
        _ key: String, bottleURL: URL, libraries: inout [URL: FolderGameLibrary]
    ) throws {
        var library = try FolderGameLibrary.load(bottleURL: bottleURL)
        guard library.pendingMetadata.remove(key) != nil else {
            libraries[bottleURL] = library
            return
        }
        try library.save(bottleURL: bottleURL)
        libraries[bottleURL] = library
    }

    private var filteredEmptyState: some View {
        ContentUnavailableView {
            Label("library.visibility.empty", systemImage: search.isEmpty ? "eye.slash" : "magnifyingglass")
        } description: {
            Text(search.isEmpty ? "library.visibility.empty.hidden" : "library.visibility.empty.search")
        } actions: {
            if !search.isEmpty {
                Button("library.visibility.clearSearch") { search = "" }
            }
            if !showHiddenGames {
                Button("library.visibility.showAll") { showHiddenGames = true }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("library.empty.title", systemImage: "square.grid.2x2")
        } description: {
            Text(bottles.isEmpty ? "library.empty.noBottle" : "library.empty.noPrograms")
        } actions: {
            if let first = bottles.first {
                Button("library.empty.pinHint") { selectedBottle = first.url }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

// swiftlint:enable type_body_length

private struct LibraryHiddenBadge: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if hidden {
                Label("library.visibility.hidden", systemImage: "eye.slash")
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct LibraryFolderSettings: View {
    let bottles: [Bottle]
    let initialBottleURL: URL?
    let didSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var bottleURL: URL?
    @State private var library = FolderGameLibrary()
    @State private var error: String?
    @State private var includePinnedAndSteam = true
    @State private var movingRoot = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("library.scan.folders").font(.title2).bold()
                Spacer()
                Button("button.ok") { didSave()
                    dismiss()
                }
            }
            Picker("library.sort.bottle", selection: $bottleURL) {
                ForEach(bottles, id: \.url) { bottle in
                    Text(bottle.settings.name).tag(Optional(bottle.url))
                }
            }
            Toggle("library.scan.metadata", isOn: $library.automaticMetadata)
                .onChange(of: library.automaticMetadata) { save() }
            Toggle("library.scan.existing", isOn: $includePinnedAndSteam)
                .onChange(of: includePinnedAndSteam) {
                    guard let bottleURL else { return }
                    do {
                        var visibility = try LibraryVisibility.load(bottleURL: bottleURL)
                        visibility.includePinnedAndSteam = includePinnedAndSteam
                        try visibility.save(bottleURL: bottleURL)
                    } catch { self.error = error.localizedDescription }
                }
            List {
                ForEach(library.roots, id: \.self) { root in
                    HStack {
                        Text(root).lineLimit(2).textSelection(.enabled)
                        Spacer()
                        if bottles.count > 1, let bottleURL {
                            Menu("library.scan.moveBottle") {
                                ForEach(bottles.filter { $0.url != bottleURL }, id: \.url) { target in
                                    Button(target.settings.name) {
                                        moveRoot(root, from: bottleURL, to: target.url)
                                    }
                                }
                            }
                            .fixedSize()
                        }
                        Button(role: .destructive) {
                            library.roots.removeAll { $0 == root }
                            save()
                        } label: { Image(systemName: "minus.circle") }
                    }
                }
            }
            HStack {
                Button("library.scan.add") { addRoot() }.disabled(bottleURL == nil)
                Spacer()
                Button("library.scan.now") { didSave()
                    dismiss()
                }.disabled(bottleURL == nil)
                    .buttonStyle(.borderedProminent)
            }
            if let error {
                Text(error).foregroundStyle(.red)
            }
        }
        .padding(24)
        .frame(width: 620, height: 430)
        .disabled(movingRoot)
        .onAppear {
            if let initialBottleURL, bottles.contains(where: { $0.url == initialBottleURL }) {
                bottleURL = initialBottleURL
            } else {
                bottleURL = bottles.first?.url
            }
            load()
        }
        .onChange(of: bottleURL) { load() }
    }

    private func load() {
        guard let bottleURL else { return }
        do {
            library = try FolderGameLibrary.load(bottleURL: bottleURL)
            includePinnedAndSteam = try LibraryVisibility.load(bottleURL: bottleURL).includePinnedAndSteam
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func moveRoot(_ root: String, from sourceBottleURL: URL, to targetBottleURL: URL) {
        guard !movingRoot else { return }
        movingRoot = true
        Task { @MainActor in
            defer { movingRoot = false }
            do {
                try await FolderGameLibrary.moveRoot(root, from: sourceBottleURL, to: targetBottleURL)
                load()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func save() {
        guard let bottleURL else { return }
        do {
            // Preserve executable selections made since the settings were opened.
            var current = try FolderGameLibrary.load(bottleURL: bottleURL)
            current.roots = library.roots
            current.excludedFolders = library.excludedFolders
            current.initializedRoots.formIntersection(Set(library.roots))
            let assignedSet = Set(current.assignedFolders)
            current.pendingMetadata = current.pendingMetadata.filter { key in
                if assignedSet.contains(key) {
                    return true
                }
                let parentPath = FolderGameLibrary.url(for: key, bottleURL: bottleURL)
                    .deletingLastPathComponent().standardizedFileURL.path
                return library.roots.contains {
                    parentPath == FolderGameLibrary.url(for: $0, bottleURL: bottleURL).standardizedFileURL.path
                }
            }
            current.automaticMetadata = library.automaticMetadata
            try current.save(bottleURL: bottleURL)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func addRoot() {
        guard let bottleURL else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = bottleURL.appendingPathComponent("drive_c")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let key = FolderGameLibrary.key(for: url, bottleURL: bottleURL)
            if !library.roots.contains(key) {
                library.roots.append(key)
            }
            let rootStandardPath = url.standardizedFileURL.path
            library.excludedFolders = library.excludedFolders.filter { excludedKey in
                let parentPath = FolderGameLibrary.url(for: excludedKey, bottleURL: bottleURL)
                    .deletingLastPathComponent().standardizedFileURL.path
                return parentPath != rootStandardPath
            }
            do {
                var visibility = try LibraryVisibility.load(bottleURL: bottleURL)
                let prefix = "program:" + key.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
                visibility.hiddenIdentities = visibility.hiddenIdentities.filter {
                    !$0.hasPrefix(prefix) && !$0.hasPrefix("program:" + key + "/")
                }
                try visibility.save(bottleURL: bottleURL)
            } catch { self.error = error.localizedDescription
                return
            }
        }
        save()
    }
}
