// swiftlint:disable file_length
//
//  LibraryGameSheet.swift
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

import SwiftUI
import UniformTypeIdentifiers
import WhiskyKit

/// Browsing metadata is separate from launching; accepting a candidate is explicit.
struct LibraryGameSheet: View {
    let item: LibraryEntry
    let bottles: [Bottle]
    let launch: () -> Void
    let moveBottle: (Bottle) -> Void
    let didSave: () -> Void

    @AppStorage("libraryDetailBlurredBackground") private var blurredDetailBackground = true
    @Environment(\.dismiss) private var dismiss
    @State private var metadata: GameMetadata?
    @State private var coverSettings = GameCoverSettings()
    @State private var query = ""
    @State private var results: [GameMetadataSearchResult] = []
    @AppStorage("libraryMetadataEnabledSources") private var enabledSourceIDs = "bangumi,vndb,steam,ymgal"
    @State private var searching = false
    @State private var saving = false
    @State private var searchTask: Task<Void, Never>?
    @State private var error: String?

    private var store: GameMetadataStore {
        GameMetadataStore(directory: item.metadataDirectory)
    }

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
                if case .program = item.launch, bottles.count > 1 {
                    Picker("library.bottle.target", selection: Binding(
                        get: { item.bottleURL },
                        set: { targetURL in
                            guard let target = bottles.first(where: { $0.url == targetURL }) else { return }
                            moveBottle(target)
                        }
                    )) {
                        ForEach(bottles, id: \.url) { bottle in
                            Text(bottle.settings.name).tag(bottle.url)
                        }
                    }
                    .frame(maxWidth: 240)
                }
                Button("button.ok") { dismiss() }
            }
            .modifier(LibraryDetailReadingPanel(enabled: usesDetailBackground))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    coverEditor
                    if let metadata {
                        HStack(alignment: .top, spacing: 18) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(metadata.originalTitle).foregroundStyle(.secondary)
                                Text([metadata.developer, metadata.releaseDate]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                if let url = metadata.pageURL {
                                    Link(metadata.source.title, destination: url)
                                }
                                Button("button.run") { launch()
                                    dismiss()
                                }
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
                            Button("button.cancel") { searchTask?.cancel()
                                searching = false
                            }
                        }
                    }
                    HStack {
                        ForEach(GameMetadataSource.allCases.filter { $0 != .hikarinagi }) { source in
                            Toggle(source.title, isOn: Binding(
                                get: { enabled.contains(source) },
                                set: {
                                    if $0 {
                                        enabled.insert(source)
                                    } else {
                                        enabled.remove(source)
                                    }
                                }
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
                                cover(candidate.thumbnailURL ?? candidate.coverURL).frame(width: 52, height: 78)
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
                .modifier(LibraryDetailReadingPanel(enabled: usesDetailBackground))
            }
            if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                    .modifier(LibraryDetailReadingPanel(enabled: usesDetailBackground))
            }
        }
        .padding(24)
        .frame(width: 720, height: 620)
        .background {
            if usesDetailBackground {
                LibraryMetadataArtwork(url: selectedCoverURL, directory: item.metadataDirectory, backgroundOnly: true)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .clipped()
        .task(id: item.id) {
            query = item.source == .folder ? FolderGameMatching.query(item.name) : item.name
            do {
                metadata = try await store.load(for: item.metadataIdentity)
                coverSettings = try await store.loadCoverSettings(for: item.metadataIdentity)
            } catch {
                self.error = error.localizedDescription
            }
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

extension LibraryGameSheet {
    private var coverEditor: some View {
        HStack(alignment: .top, spacing: 18) {
            LibraryMetadataArtwork(url: selectedCoverURL, directory: item.metadataDirectory, settings: coverSettings)
                .frame(width: 150, height: 225)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 10) {
                Text("library.cover.title").font(.headline)
                Toggle("library.details.blurredBackground", isOn: $blurredDetailBackground)
                    .help("library.details.blurredBackground.help")
                Toggle("library.cover.custom", isOn: $coverSettings.useCustomCover)
                    .disabled(store.customCoverURL(for: coverSettings) == nil)
                    .onChange(of: coverSettings.useCustomCover) { persistCoverSettings() }
                Button("library.cover.choose") { chooseCover() }
                    .disabled(saving)
                Text("library.cover.zoom").font(.caption)
                Slider(value: $coverSettings.zoom, in: 1 ... 1.3, onEditingChanged: { editing in
                    if !editing { persistCoverSettings() }
                })
                .accessibilityLabel(Text("library.cover.zoom"))
                if coverSettings.zoom > 1 {
                    Text("library.cover.horizontal").font(.caption)
                    Slider(value: $coverSettings.horizontalPosition, in: 0 ... 1, onEditingChanged: { editing in
                        if !editing { persistCoverSettings() }
                    })
                    .accessibilityLabel(Text("library.cover.horizontal"))
                    Text("library.cover.vertical").font(.caption)
                    Slider(value: $coverSettings.verticalPosition, in: 0 ... 1, onEditingChanged: { editing in
                        if !editing { persistCoverSettings() }
                    })
                    .accessibilityLabel(Text("library.cover.vertical"))
                }
                Button("library.cover.reset") {
                    coverSettings.zoom = 1
                    coverSettings.horizontalPosition = 0.5
                    coverSettings.verticalPosition = 0.5
                    persistCoverSettings()
                }
            }
        }
    }

    private var usesDetailBackground: Bool {
        blurredDetailBackground && selectedCoverURL != nil
    }

    private var selectedCoverURL: URL? {
        if coverSettings.useCustomCover, let url = store.customCoverURL(for: coverSettings) { return url }
        return metadata?.coverURL
    }

    private func persistCoverSettings() {
        let settings = coverSettings
        Task {
            do {
                try await store.saveCoverSettings(settings, for: item.metadataIdentity)
                didSave()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func chooseCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .webP]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            saving = true
            Task {
                defer { saving = false }
                do {
                    let data = try await Task.detached { try Data(contentsOf: url, options: .mappedIfSafe) }.value
                    coverSettings = try await store.importCover(data, for: item.metadataIdentity)
                    didSave()
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}

struct LibraryCoverCard: View {
    let item: LibraryEntry
    let metadata: GameMetadata?
    let bottleName: String?
    let state: LibraryEntryState
    let details: () -> Void
    let launch: () -> Void
    var coverHeight: CGFloat?
    var adaptToFrame = false
    var coverAspectRatioDidLoad: (Double) -> Void = { _ in }
    var coverRevision = 0
    @AppStorage("librarySingleLineTitles") private var singleLineTitles = false
    @AppStorage("libraryCenterWideCoverText") private var centerCaption = false
    @State private var coverSettings = GameCoverSettings()

    private var coverURL: URL? {
        let store = GameMetadataStore(directory: item.metadataDirectory)
        if coverSettings.useCustomCover, let url = store.customCoverURL(for: coverSettings) { return url }
        return metadata?.coverURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            coverButton
            VStack(alignment: centerCaption ? .center : .leading, spacing: 4) {
                Text(metadata?.title ?? item.name)
                    .font(.headline)
                    .lineLimit(singleLineTitles ? 1 : 2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(centerCaption ? .center : .leading)
                    .frame(maxWidth: .infinity, alignment: centerCaption ? .top : .topLeading)
                    .help(metadata?.title ?? item.name)
                status
            }
            .frame(height: singleLineTitles ? 40 : 58, alignment: centerCaption ? .top : .topLeading)
        }
        .task(id: "\(item.id):\(coverRevision)") {
            coverSettings = await (try? GameMetadataStore(directory: item.metadataDirectory)
                .loadCoverSettings(for: item.metadataIdentity)) ?? GameCoverSettings()
        }
    }

    private var coverButton: some View {
        Button(action: details) {
            LibraryCoverSurface(height: coverHeight)
                .overlay {
                    if let url = coverURL {
                        LibraryMetadataArtwork(
                            url: url, directory: item.metadataDirectory, settings: coverSettings,
                            adaptToFrame: adaptToFrame, imageDidLoad: coverAspectRatioDidLoad
                        )
                    } else {
                        placeholder
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(metadata?.title ?? item.name)
        .accessibilityHint(Text("library.metadata.details"))
        .overlay(alignment: .bottomTrailing) {
            Button(action: launch) {
                Image(systemName: "play.fill")
                    .font(.system(size: 12))
                    .frame(width: 30, height: 30)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(state != .idle)
            .accessibilityLabel(Text("button.run"))
            .padding(8)
        }
    }

    private var status: some View {
        ZStack(alignment: centerCaption ? .center : .leading) {
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
                HStack(spacing: 4) {
                    Text(item.source == .steam ? "library.source.steam" : "library.source.local")
                    if let bottleName {
                        Text("·")
                        Text(bottleName)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
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

/// An explicit height uses the whole column span; portrait mode keeps its ratio.
private struct LibraryCoverSurface: View {
    var height: CGFloat?

    var body: some View {
        if let height {
            Rectangle().fill(.quaternary)
                .frame(maxWidth: .infinity)
                .frame(height: height)
        } else {
            Rectangle().fill(.quaternary)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
        }
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
                    if loading {
                        ProgressView()
                    }
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
                if let error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
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
                    ) {
                        select(url)
                    }
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
    var settings = GameCoverSettings()
    var backgroundOnly = false
    var adaptToFrame = false
    var imageDidLoad: (Double) -> Void = { _ in }
    @AppStorage("libraryCoverFillStyle") private var fillStyle = "blurred"
    @AppStorage("libraryBlurredCoverFill") private var blurredCoverFill = true
    @State private var cachedImage: NSImage?
    @State private var palette: IconPalette = .neutral

    private var localURL: URL? {
        guard let url else { return nil }
        if url.isFileURL { return url }
        return GameMetadataStore(directory: directory).cachedCoverURL(for: url)
    }

    var body: some View {
        Group {
            if backgroundOnly {
                LibraryDetailBackdrop(image: cachedImage)
            } else if let cachedImage {
                artwork(cachedImage)
            } else {
                Rectangle().fill(.quaternary).overlay { Image(systemName: "photo") }
            }
        }
        .onChange(of: cachedImage) {
            if let cachedImage, cachedImage.size.height > 0 {
                imageDidLoad(cachedImage.size.width / cachedImage.size.height)
            }
        }
        .task(id: localURL ?? url) {
            cachedImage = nil
            if let local = localURL {
                let image = await Task.detached { NSImage(contentsOf: local) }.value
                guard !Task.isCancelled else { return }
                cachedImage = image
                if let image { palette = IconPalette.palette(for: image) }
            } else if let url {
                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    guard !Task.isCancelled,
                          let response = response as? HTTPURLResponse,
                          (200 ..< 300).contains(response.statusCode)
                    else { return }
                    cachedImage = NSImage(data: data)
                    if let cachedImage { palette = IconPalette.palette(for: cachedImage) }
                } catch {
                    // Keep the placeholder visible until the next load.
                }
            }
        }
    }

    private func artwork(_ image: NSImage) -> some View {
        GeometryReader { geometry in
            let size = geometry.size
            let fit = min(size.width / max(image.size.width, 1), size.height / max(image.size.height, 1))
            let fill = max(size.width / max(image.size.width, 1), size.height / max(image.size.height, 1))
            let scale = adaptToFrame ? fill : fit
            let stretch = adaptToFrame && LibraryCoverGrid.shouldStretch(
                imageAspect: image.size.width / max(image.size.height, 1),
                targetAspect: size.width / max(size.height, 1)
            )
            let zoom = min(max(settings.zoom, 1), 1.3)
            let width = (stretch ? size.width : image.size.width * scale) * zoom
            let height = (stretch ? size.height : image.size.height * scale) * zoom
            ZStack {
                if blurredCoverFill, image.size.width > image.size.height {
                    if fillStyle == "theme" {
                        LinearGradient(
                            colors: [Color(palette), Color(palette.deepened())],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    } else {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: size.width, height: size.height)
                            .blur(radius: 20)
                            .overlay { Color.black.opacity(0.2) }
                    }
                }
                Image(nsImage: image)
                    .resizable()
                    .frame(width: width, height: height)
                    .position(
                        x: position(length: width, available: size.width, fraction: settings.horizontalPosition),
                        y: position(length: height, available: size.height, fraction: settings.verticalPosition)
                    )
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
    }

    private func position(length: CGFloat, available: CGFloat, fraction: Double) -> CGFloat {
        length / 2 + (available - length) * min(max(fraction, 0), 1)
    }
}

/// A semantic scrim preserves the system's text palette in both appearances.
private struct LibraryDetailBackdrop: View {
    let image: NSImage?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .overlay {
                if let image, !reduceTransparency {
                    GeometryReader { geometry in
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width + 80, height: geometry.size.height + 80)
                            .blur(radius: 32)
                            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    }
                    .clipped()
                    .overlay {
                        Color(nsColor: .windowBackgroundColor)
                            .opacity(contrast == .increased ? 0.92 : (colorScheme == .dark ? 0.7 : 0.78))
                    }
                }
            }
    }
}

private struct LibraryDetailReadingPanel: ViewModifier {
    let enabled: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .padding(enabled ? 14 : 0)
            .background {
                if enabled {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(nsColor: .textBackgroundColor)
                            .opacity(reduceTransparency || contrast == .increased ? 1 : 0.86))
                }
            }
    }
}
