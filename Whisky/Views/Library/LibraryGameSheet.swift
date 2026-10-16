// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import WhiskyKit

/// Browsing metadata is separate from launching; accepting a candidate is explicit.
struct LibraryGameSheet: View {
    let item: LibraryEntry
    let launch: () -> Void
    let didSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var metadata: GameMetadata?
    @State private var query = ""
    @State private var results: [GameMetadataSearchResult] = []
    @AppStorage("libraryMetadataEnabledSources") private var enabledSourceIDs = "bangumi,vndb,steam,ymgal"
    @State private var searching = false
    @State private var saving = false
    @State private var searchTask: Task<Void, Never>?
    @State private var error: String?

    private var store: GameMetadataStore { GameMetadataStore(directory: item.metadataDirectory) }

    private var enabled: Set<GameMetadataSource> {
        get {
            Set(enabledSourceIDs.split(separator: ",").compactMap {
                GameMetadataSource(rawValue: String($0))
            })
        }
        nonmutating set {
            enabledSourceIDs = newValue.map(\.rawValue).sorted().joined(separator: ",")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(metadata?.title ?? item.name).font(.title2).bold()
                Spacer()
                Button("button.ok") { dismiss() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let metadata {
                        HStack(alignment: .top, spacing: 18) {
                            cover(metadata.coverURL)
                                .frame(width: 150, height: 225)
                            VStack(alignment: .leading, spacing: 10) {
                                Text(metadata.originalTitle).foregroundStyle(.secondary)
                                Text([metadata.developer, metadata.releaseDate]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                if let url = metadata.pageURL {
                                    Link(metadata.source.title, destination: url)
                                }
                                Button("button.run") { launch(); dismiss() }
                                    .buttonStyle(.borderedProminent)
                                Button("library.metadata.unlink", role: .destructive) {
                                    Task { await unlink() }
                                }
                            }
                        }
                        Text(metadata.summary).textSelection(.enabled)
                        Divider()
                    }
                    Text("library.metadata.search").font(.headline)
                    HStack {
                        TextField("library.metadata.query", text: $query)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { startSearch() }
                        Button("library.metadata.search") { startSearch() }
                            .disabled(searching || enabled.isEmpty
                                || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if searching {
                            ProgressView().controlSize(.small)
                            Button("button.cancel") { searchTask?.cancel(); searching = false }
                        }
                    }
                    HStack {
                        ForEach(GameMetadataSource.allCases.filter { $0 != .hikarinagi }) { source in
                            Toggle(source.title, isOn: Binding(
                                get: { enabled.contains(source) },
                                set: { if $0 { enabled.insert(source) } else { enabled.remove(source) } }
                            ))
                            .toggleStyle(.checkbox)
                        }
                    }
                    ForEach(results, id: \.source) { result in
                        Text(result.source.title).font(.headline)
                        if let error = result.error {
                            Text(error).foregroundStyle(.secondary)
                        } else if result.games.isEmpty {
                            Text("library.metadata.empty").foregroundStyle(.secondary)
                        }
                        ForEach(FolderGameMatching.ranked(query: query, games: result.games)) { candidate in
                            HStack(alignment: .top) {
                                cover(candidate.coverURL).frame(width: 52, height: 78)
                                VStack(alignment: .leading) {
                                    Text(candidate.title).bold()
                                    Text(candidate.originalTitle).font(.caption)
                                    Text(candidate.releaseDate).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("library.metadata.use") {
                                    Task { await save(candidate) }
                                }
                                .disabled(saving)
                            }
                        }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .padding(24)
        .frame(width: 720, height: 620)
        .task {
            query = item.source == .folder ? FolderGameMatching.query(item.name) : item.name
            do { metadata = try await store.load(for: item.metadataIdentity) }
            catch { self.error = error.localizedDescription }
        }
        .onDisappear { searchTask?.cancel() }
    }

    private func cover(_ url: URL?) -> some View {
        LibraryMetadataArtwork(url: url, directory: item.metadataDirectory)
    }

    private func startSearch() {
        guard !searching, !enabled.isEmpty else { return }
        searchTask?.cancel()
        searching = true
        error = nil
        let providers = GameMetadataSource.allCases.filter { enabled.contains($0) && $0 != .hikarinagi }
            .map { PublicGameMetadataProvider(source: $0) }
        let keyword = query
        searchTask = Task {
            let found = await GameMetadataSearch.search(keyword, providers: providers)
            guard !Task.isCancelled else { return }
            results = found
            searching = false
        }
    }

    private func save(_ candidate: GameMetadata) async {
        guard !saving else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            let candidate = try await PublicGameMetadataProvider(source: candidate.source)
                .details(for: candidate).usingLibraryTitle(item.name)
            try await store.save(candidate, for: item.metadataIdentity)
            metadata = candidate
            didSave()
            if let url = candidate.coverURL {
                try await store.cacheCover(from: url)
                didSave()
            }
        } catch { self.error = error.localizedDescription }
    }

    private func unlink() async {
        do {
            try await store.remove(for: item.metadataIdentity)
            metadata = nil
            didSave()
        } catch { self.error = error.localizedDescription }
    }
}

struct LibraryCoverCard: View {
    let item: LibraryEntry
    let metadata: GameMetadata?
    let state: LibraryEntryState
    let details: () -> Void
    let launch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: details) {
                Rectangle().fill(.quaternary)
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .overlay {
                        if let url = metadata?.coverURL {
                            LibraryMetadataArtwork(url: url, directory: item.metadataDirectory)
                        } else { placeholder }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(metadata?.title ?? item.name)
            .accessibilityHint(Text("library.metadata.details"))
            HStack(alignment: .top) {
                Text(metadata?.title ?? item.name)
                    .font(.headline)
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                Spacer(minLength: 0)
                Button(action: launch) {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .disabled(state != .idle)
                .accessibilityLabel(Text("button.run"))
            }
            ZStack(alignment: .leading) {
                Color.clear.frame(height: 18)
                if state == .running {
                    Label("library.card.running", systemImage: "circle.fill")
                        .font(.caption).foregroundStyle(.green)
                } else if state.isPending {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text(state.phaseLabel).font(.caption).lineLimit(1)
                    }
                } else {
                    Text(item.source == .steam ? "library.source.steam" : "library.source.local")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "gamecontroller").font(.largeTitle)
            Text(item.name).font(.caption).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary).padding()
    }
}

/// Steam owns launch options and DRM; Whisky exposes only its compatibility
/// layer here. Picking an executable is an explicit advanced action.
struct LibrarySteamSettingsSheet: View {
    let bottle: Bottle
    let appID: Int
    let title: String
    let openBottle: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var game: SteamGame?
    @State private var candidates: [URL] = []
    @State private var selectedURL: URL?
    @State private var program: Program?
    @State private var overridesExpanded = true
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.title2).bold()
                Spacer()
                Button("button.ok") { dismiss() }
            }.padding()
            Form {
                Section("library.steam.management") {
                    Text("library.steam.managedOptions").foregroundStyle(.secondary)
                    Button("library.steam.openClient") { openSteam() }
                    if let game {
                        Button("button.showInFinder") {
                            NSWorkspace.shared.activateFileViewerSelecting([game.installURL])
                        }
                    }
                }
                Section("library.steam.compatibility") {
                    Text("library.steam.runtimeScope").foregroundStyle(.secondary)
                    Button("library.card.configure", action: openBottle)
                    if loading { ProgressView() }
                    if !candidates.isEmpty {
                        Picker("library.steam.overrideTarget", selection: Binding(
                            get: { selectedURL },
                            set: { select($0) }
                        )) {
                            Text("library.steam.chooseTarget").tag(nil as URL?)
                            ForEach(candidates, id: \.self) { url in
                                Text(relativePath(url)).tag(Optional(url))
                            }
                        }
                    } else if !loading {
                        Text("library.steam.noExecutables").foregroundStyle(.secondary)
                    }
                }
                if let program {
                    ProgramOverrideSettingsView(
                        bottle: bottle, program: program, isExpanded: $overridesExpanded
                    )
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            .formStyle(.grouped)
        }
        .frame(width: 680, height: 620)
        .task {
            let root = bottle.url
            let id = appID
            let found = await Task.detached {
                let game = SteamLibrary.enumerate(bottleURL: root).first { $0.appId == id }
                return (game, game.map { SteamLibrary.executableURLs(under: $0.installURL) } ?? [])
            }.value
            guard !Task.isCancelled else { return }
            game = found.0
            candidates = found.1.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            loading = false
            if let game {
                do {
                    if let url = try SteamGameProgram.selectedURL(
                        appID: appID, installURL: game.installURL, bottleURL: bottle.url
                    ) { select(url) }
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    private func relativePath(_ url: URL) -> String {
        guard let game else { return url.lastPathComponent }
        return String(url.path.dropFirst(game.installURL.path.count + 1))
    }

    private func select(_ url: URL?) {
        do {
            guard let url, let game else {
                try SteamGameProgram.clear(appID: appID, bottleURL: bottle.url)
                selectedURL = nil
                program = nil
                return
            }
            try SteamGameProgram.select(url, appID: appID, installURL: game.installURL, bottleURL: bottle.url)
            selectedURL = url
            program = bottle.programs.first(where: { $0.url == url })
                ?? Program(url: url, bottle: bottle, peFile: nil)
        } catch { self.error = error.localizedDescription }
    }

    private func openSteam() {
        guard let root = SteamLibrary.detectInstall(bottleURL: bottle.url) else { return }
        Task {
            do {
                // Use this bottle's Windows client, never the macOS Steam app.
                let client = Program(url: root.appendingPathComponent("steam.exe"), bottle: bottle, peFile: nil)
                try await client.launch(args: ["steam://nav/games/details/\(appID)"])
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct LibraryMetadataArtwork: View {
    let url: URL?
    let directory: URL
    @State private var cachedImage: NSImage?

    var body: some View {
        Group {
            if let cachedImage {
                Image(nsImage: cachedImage).resizable().scaledToFit()
            } else {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Rectangle().fill(.quaternary).overlay { Image(systemName: "photo") }
                }
            }
        }
        .task(id: url) {
            cachedImage = nil
            if let url,
               let local = await GameMetadataStore(directory: directory).cachedCoverURL(for: url) {
                cachedImage = NSImage(contentsOf: local)
            }
        }
    }
}
