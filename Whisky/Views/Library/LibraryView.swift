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
import WhiskyKit
import UniformTypeIdentifiers

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

    @AppStorage("librarySort") private var sort: LibrarySort = .recent
    @AppStorage("libraryCoverMode") private var coverMode = false

    @StateObject private var model = LibraryModel()
    @State private var search: String = ""
    @State private var detailRow: LibraryRow?
    @State private var settingsProgram: Program?
    @State private var steamSettingsRow: LibraryRow?
    @State private var metadata: [String: GameMetadata] = [:]
    @State private var metadataRevision = 0
    @State private var metadataError: String?
    @State private var showScanSettings = false
    @State private var manualSync = false
    @State private var syncing = false
    @AppStorage("libraryMetadataEnabledSources") private var enabledSourceIDs = "bangumi,vndb,steam,ymgal"

    private var bottles: [Bottle] { bottleVM.bottles.filter(\.isAvailable) }

    private var visible: [LibraryRow] {
        guard !search.isEmpty else { return model.rows }
        return model.rows.filter {
            $0.item.name.localizedCaseInsensitiveContains(search)
                || metadata[$0.id]?.title.localizedCaseInsensitiveContains(search) == true
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
            } else {
                grid
            }
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
                launch: { model.launch(row, bottles: bottles) },
                didSave: { metadataRevision += 1 }
            )
        }
        .sheet(isPresented: $showScanSettings) {
            LibraryFolderSettings(bottles: bottles) { refresh.toggle() }
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
        .onDisappear {
            model.stopTracking()
        }
        .alert(
            Text(model.launchError == nil ? "library.metadata.error" : "library.launch.failed"),
            isPresented: Binding(
                get: { model.launchError != nil || metadataError != nil },
                set: { if !$0 { model.launchError = nil; metadataError = nil } }
            )
        ) {
            Button("button.ok") { model.launchError = nil; metadataError = nil }
        } message: {
            Text(model.launchError ?? metadataError ?? "")
        }
    }

    @ToolbarContentBuilder
    private var sortMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
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
            .help("library.sync.manual")
            .accessibilityIdentifier("library.scanAndSync")
            .disabled(syncing)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { showScanSettings = true } label: {
                Label("library.scan.folders", systemImage: "folder.badge.plus")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { coverMode.toggle() } label: {
                Label(
                    coverMode ? "library.view.classic" : "library.view.covers",
                    systemImage: coverMode ? "rectangle.grid.2x2" : "books.vertical"
                )
            }
            .accessibilityIdentifier("library.view.toggle")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("library.sort", selection: $sort) {
                    ForEach(LibrarySort.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("library.sort", systemImage: "arrow.up.arrow.down")
            }
            .accessibilityIdentifier("library.sort")
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                // 180 rather than 220 so two columns fit at the window's own
                // minimum width, where the sidebar leaves about 330pt: one
                // column of landscape cards is a list with wasted space.
                columns: [GridItem(.adaptive(
                    minimum: coverMode ? 140 : 180, maximum: coverMode ? 200 : 320
                ), spacing: coverMode ? 22 : 14, alignment: .top)],
                alignment: .leading,
                spacing: coverMode ? 28 : 14
            ) {
                ForEach(visible) { row in
                    Group {
                        if coverMode {
                            LibraryCoverCard(
                                item: row.item, metadata: metadata[row.id],
                                state: model.state(for: row.item), details: { detailRow = row },
                                launch: { model.launch(row, bottles: bottles) }
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
                    .contextMenu { menu(for: row) }
                }
            }
            .padding(18)
        }
    }

    @ViewBuilder
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
        Button("library.remove", role: .destructive) {
            model.removeFromLibrary(row.item, bottles: bottles)
        }
        if !row.item.isLauncher {
            Button("library.metadata.details") { detailRow = row }
        }
        if case let .program(url) = row.item.launch {
            if row.item.source == .folder {
                Button("library.scan.executable") { _ = model.folderExecutable(row.item, chooseAgain: true) }
            }
            Button("library.program.settings") {
                guard let bottle = bottles.first(where: { $0.url == row.item.bottleURL }) else { return }
                guard let executable = row.item.source == .folder ? model.folderExecutable(row.item) : url else { return }
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

    private func loadMetadata() async {
        syncing = true
        let requested = manualSync
        manualSync = false
        defer { syncing = false }
        var loaded: [String: GameMetadata] = [:]
        for row in model.rows {
            guard !Task.isCancelled else { return }
            do {
                let store = GameMetadataStore(directory: row.item.metadataDirectory)
                loaded[row.id] = try await store.load(for: row.item.metadataIdentity)
                if !Task.isCancelled { metadata[row.id] = loaded[row.id] }
                let library = try FolderGameLibrary.load(bottleURL: row.item.bottleURL)
                let folderKey: String? = {
                    guard row.item.source == .folder, case let .program(folder) = row.item.launch else { return nil }
                    return FolderGameLibrary.key(for: folder, bottleURL: row.item.bottleURL)
                }()
                if loaded[row.id] == nil, let folderKey,
                   requested || (library.automaticMetadata && library.pendingMetadata.contains(folderKey)),
                   try await store.allowsAutomaticMatch(for: row.item.metadataIdentity) {
                    let sources = GameMetadataSource.allCases.filter {
                        enabledSourceIDs.split(separator: ",").contains(Substring($0.rawValue))
                            && $0 != .hikarinagi
                    }
                    if !sources.isEmpty {
                        let query = FolderGameMatching.query(row.item.name)
                        let results = await GameMetadataSearch.search(query, providers: sources.map {
                            PublicGameMetadataProvider(source: $0)
                        })
                        try Task.checkCancellation()
                        try completeInitialMatch(folderKey, bottleURL: row.item.bottleURL)
                        if let candidate = FolderGameMatching.candidate(query: query, results: results, sources: sources) {
                            let details = try await PublicGameMetadataProvider(source: candidate.source)
                                .details(for: candidate).usingLibraryTitle(row.item.name)
                            try Task.checkCancellation()
                            try await store.saveAutomatic(details, for: row.item.metadataIdentity)
                            loaded[row.id] = try await store.load(for: row.item.metadataIdentity)
                            if let cover = details.coverURL { try? await store.cacheCover(from: cover) }
                        }
                    }
                } else if let folderKey, library.pendingMetadata.contains(folderKey) {
                    try completeInitialMatch(folderKey, bottleURL: row.item.bottleURL)
                }
            } catch is CancellationError {
                return
            } catch {
                // Do not replace corrupt metadata with defaults or affect launching.
                metadataError = error.localizedDescription
            }
        }
        if !Task.isCancelled { metadata = loaded }
    }

    private func completeInitialMatch(_ key: String, bottleURL: URL) throws {
        var library = try FolderGameLibrary.load(bottleURL: bottleURL)
        library.pendingMetadata.remove(key)
        try library.save(bottleURL: bottleURL)
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

private struct LibraryFolderSettings: View {
    let bottles: [Bottle]
    let didSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var bottleURL: URL?
    @State private var library = FolderGameLibrary()
    @State private var error: String?
    @State private var includePinnedAndSteam = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("library.scan.folders").font(.title2).bold()
                Spacer()
                Button("button.ok") { didSave(); dismiss() }
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
                Button("library.scan.now") { didSave(); dismiss() }.disabled(bottleURL == nil)
                    .buttonStyle(.borderedProminent)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .padding(24)
        .frame(width: 620, height: 430)
        .onAppear { bottleURL = bottles.first?.url; load() }
        .onChange(of: bottleURL) { load() }
    }

    private func load() {
        guard let bottleURL else { return }
        do {
            library = try FolderGameLibrary.load(bottleURL: bottleURL)
            includePinnedAndSteam = try LibraryVisibility.load(bottleURL: bottleURL).includePinnedAndSteam
            error = nil
        }
        catch { self.error = error.localizedDescription }
    }

    private func save() {
        guard let bottleURL else { return }
        do {
            // Preserve executable selections made since the settings were opened.
            var current = try FolderGameLibrary.load(bottleURL: bottleURL)
            current.roots = library.roots
            current.initializedRoots.formIntersection(Set(library.roots))
            current.pendingMetadata = current.pendingMetadata.filter { key in
                library.roots.contains {
                    FolderGameLibrary.url(for: key, bottleURL: bottleURL).deletingLastPathComponent().path
                        == FolderGameLibrary.url(for: $0, bottleURL: bottleURL).path
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
            if !library.roots.contains(key) { library.roots.append(key) }
            do {
                var visibility = try LibraryVisibility.load(bottleURL: bottleURL)
                visibility.hiddenIdentities = visibility.hiddenIdentities.filter {
                    !$0.hasPrefix("program:" + key + "/")
                }
                try visibility.save(bottleURL: bottleURL)
            } catch { self.error = error.localizedDescription; return }
        }
        save()
    }
}
