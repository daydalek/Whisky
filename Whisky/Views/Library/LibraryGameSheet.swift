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

enum LibraryDetailLayoutStyle: String, CaseIterable, Identifiable {
    case hero
    case split

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .hero: return "library.detail.layout.hero"
        case .split: return "library.detail.layout.split"
        }
    }

    var icon: String {
        switch self {
        case .hero: return "sparkles"
        case .split: return "sidebar.left"
        }
    }
}

enum SplitDetailTab: String, CaseIterable, Identifiable {
    case overview
    case cover
    case metadata

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .overview: return "library.detail.tab.overview"
        case .cover: return "library.detail.tab.cover"
        case .metadata: return "library.detail.tab.metadata"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "text.alignleft"
        case .cover: return "photo.artframe"
        case .metadata: return "magnifyingglass"
        }
    }
}

/// Browsing metadata is separate from launching; accepting a candidate is explicit.
struct LibraryGameSheet: View {
    let item: LibraryEntry
    let bottles: [Bottle]
    let launch: () -> Void
    let moveBottle: (Bottle) -> Void
    let didSave: () -> Void

    @AppStorage("libraryDetailBlurredBackground") var blurredDetailBackground = true
    @AppStorage("libraryDetailLayoutStyle") var layoutStyle: LibraryDetailLayoutStyle = .hero
    @Environment(\.dismiss) var dismiss
    @State var splitTab: SplitDetailTab = .overview
    @State var showCoverTunePopover = false
    @State var metadata: GameMetadata?
    @State var activity = GameActivity()
    @ObservedObject var activityTracker = GameActivityTracker.shared
    @State var coverSettings = GameCoverSettings()
    @State var query = ""
    @State var results: [GameMetadataSearchResult] = []
    @AppStorage("libraryMetadataEnabledSources") var enabledSourceIDs = "bangumi,vndb,steam,ymgal"
    @State var searching = false
    @State var saving = false
    @State var searchTask: Task<Void, Never>?
    @State var error: String?

    var store: GameMetadataStore {
        GameMetadataStore(directory: item.metadataDirectory)
    }

    var enabled: Set<GameMetadataSource> {
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
        VStack(alignment: .leading, spacing: 0) {
            navigationHeader
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            Group {
                if layoutStyle == .hero {
                    heroLayout
                } else {
                    splitLayout
                }
            }
            .padding(20)

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
        }
        .frame(width: 760, height: 640)
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
                activity = try GameActivityStore.shared.load(for: item)
            } catch {
                self.error = error.localizedDescription
            }
        }
        .task(id: "activity:\(item.id)") {
            while !Task.isCancelled {
                do {
                    activity = try GameActivityStore.shared.load(for: item)
                    try await Task.sleep(for: .seconds(10))
                } catch is CancellationError { return } catch {
                    self.error = error.localizedDescription
                    return
                }
            }
        }
        .onDisappear { searchTask?.cancel() }
    }
}

// MARK: - Navigation & Layouts

extension LibraryGameSheet {
    var navigationHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            if layoutStyle == .hero {
                if let source = metadata?.source {
                    HStack(spacing: 5) {
                        Image(systemName: "gamecontroller.fill")
                            .font(.caption2)
                        Text(source.title)
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundStyle(.secondary)
                } else {
                    Text(item.source == .steam ? "Steam" : "Game")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(metadata?.title ?? item.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            Picker("", selection: $layoutStyle) {
                ForEach(LibraryDetailLayoutStyle.allCases) { style in
                    Label(style.label, systemImage: style.icon).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()

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
                .controlSize(.small)
                .frame(maxWidth: 180)
            }

            Button("button.ok") { dismiss() }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
        }
    }

    var heroLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heroSpotlight

                if let metadata, !metadata.summary.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("library.detail.about", systemImage: "text.alignleft")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text(metadata.summary)
                            .font(.body)
                            .lineSpacing(5)
                            .textSelection(.enabled)
                            .foregroundStyle(.primary.opacity(0.92))
                    }
                    .modifier(LibraryDetailReadingPanel(enabled: usesDetailBackground))
                }

                VStack(alignment: .leading, spacing: 12) {
                    DisclosureGroup("library.cover.title") {
                        coverOptionsForm
                            .padding(.top, 8)
                    }

                    DisclosureGroup("library.metadata.search") {
                        metadataSearchForm
                            .padding(.top, 8)
                    }
                }
                .modifier(LibraryDetailReadingPanel(enabled: usesDetailBackground))
            }
        }
    }

    var splitLayout: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 14) {
                LibraryMetadataArtwork(
                    url: selectedCoverURL,
                    directory: item.metadataDirectory,
                    settings: coverSettings
                )
                .frame(width: 170, height: 242)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 5)

                Button {
                    launch()
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("button.run")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .shadow(color: .accentColor.opacity(0.3), radius: 8, x: 0, y: 3)

                splitStatsCard

                if metadata != nil {
                    Button("library.metadata.unlink", role: .destructive) {
                        Task { await unlink() }
                    }
                    .font(.caption)
                    .controlSize(.small)
                }

                Spacer()
            }
            .frame(width: 215)
            .modifier(LibraryDetailReadingPanel(enabled: usesDetailBackground))

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(metadata?.title ?? item.name)
                        .font(.title2.bold())
                        .lineLimit(2)
                        .textSelection(.enabled)

                    if let original = metadata?.originalTitle,
                       !original.isEmpty,
                       original != (metadata?.title ?? item.name) {
                        Text(original)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 6) {
                        if let dev = metadata?.developer, !dev.isEmpty {
                            Text(dev)
                        }
                        if let date = metadata?.releaseDate, !date.isEmpty {
                            Text("·")
                            Text(date)
                        }
                        if let url = metadata?.pageURL {
                            Text("·")
                            Link(metadata?.source.title ?? "Web", destination: url)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Picker("", selection: $splitTab) {
                    ForEach(SplitDetailTab.allCases) { tab in
                        Label(tab.label, systemImage: tab.icon).tag(tab)
                    }
                }
                .pickerStyle(.segmented)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        switch splitTab {
                        case .overview:
                            if let metadata, !metadata.summary.isEmpty {
                                Text(metadata.summary)
                                    .font(.body)
                                    .lineSpacing(5)
                                    .textSelection(.enabled)
                            } else {
                                Text("library.metadata.empty")
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 20)
                            }
                        case .cover:
                            coverOptionsForm
                        case .metadata:
                            metadataSearchForm
                        }
                    }
                    .padding(4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(LibraryDetailReadingPanel(enabled: usesDetailBackground))
        }
    }
}

// MARK: - Hero & Stats Components

extension LibraryGameSheet {
    var heroSpotlight: some View {
        HStack(alignment: .bottom, spacing: 22) {
            ZStack(alignment: .bottomTrailing) {
                LibraryMetadataArtwork(
                    url: selectedCoverURL,
                    directory: item.metadataDirectory,
                    settings: coverSettings
                )
                .frame(width: 154, height: 224)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 10, x: 0, y: 5)

                Button {
                    showCoverTunePopover.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.2.square")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(6)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .padding(8)
                .help("library.detail.tuneCover")
                .popover(isPresented: $showCoverTunePopover, arrowEdge: .trailing) {
                    coverTunePopover
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(metadata?.title ?? item.name)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .lineLimit(2)
                        .textSelection(.enabled)

                    if let original = metadata?.originalTitle,
                       !original.isEmpty,
                       original != (metadata?.title ?? item.name) {
                        Text(original)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                }

                HStack(spacing: 8) {
                    if let dev = metadata?.developer, !dev.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "building.2")
                            Text(dev)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if let date = metadata?.releaseDate, !date.isEmpty {
                        Text("·").foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Image(systemName: "calendar")
                            Text(date)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if let url = metadata?.pageURL {
                        Text("·").foregroundStyle(.secondary)
                        Link(destination: url) {
                            HStack(spacing: 3) {
                                Text(metadata?.source.title ?? "Web")
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 9))
                            }
                            .font(.caption.weight(.medium))
                        }
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 12) {
                    Button {
                        launch()
                        dismiss()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                            Text("button.run")
                        }
                        .font(.headline)
                        .padding(.horizontal, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .shadow(color: .accentColor.opacity(0.3), radius: 8, x: 0, y: 3)

                    heroStatsBar
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .modifier(LibraryDetailReadingPanel(enabled: usesDetailBackground))
    }

    var heroStatsBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("library.activity.playTime")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(Duration.seconds(activity.playTime).formatted(.units(
                        allowed: [.hours, .minutes], width: .abbreviated
                    )))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                }
            }

            Divider().frame(height: 22)

            HStack(spacing: 6) {
                Image(systemName: "star.fill")
                    .foregroundStyle(activity.rating != nil ? .yellow : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("library.activity.rating")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Menu {
                        Button("library.activity.unrated") { setRating(nil) }
                        ForEach(1 ... 10, id: \.self) { score in
                            Button {
                                setRating(score)
                            } label: {
                                if activity.rating == score {
                                    Label("\(score) / 10", systemImage: "checkmark")
                                } else {
                                    Text("\(score) / 10")
                                }
                            }
                        }
                    } label: {
                        if let rating = activity.rating {
                            Text("\(rating) / 10").font(.system(size: 13, weight: .semibold))
                        } else {
                            Text("library.activity.unrated").font(.system(size: 12))
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            if let lastPlayed = activity.lastPlayed {
                Divider().frame(height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("library.activity.lastPlayed")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(lastPlayed, style: .date)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    var splitStatsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("library.activity.playTime", systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(Duration.seconds(activity.playTime).formatted(.units(
                    allowed: [.hours, .minutes], width: .abbreviated
                )))
                .font(.subheadline.weight(.semibold)).monospacedDigit()
            }

            Divider()

            HStack {
                Label("library.activity.rating", systemImage: "star.fill")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("library.activity.unrated") { setRating(nil) }
                    ForEach(1 ... 10, id: \.self) { score in
                        Button {
                            setRating(score)
                        } label: {
                            if activity.rating == score {
                                Label("\(score) / 10", systemImage: "checkmark")
                            } else {
                                Text("\(score) / 10")
                            }
                        }
                    }
                } label: {
                    if let rating = activity.rating {
                        Text("\(rating) / 10").font(.subheadline.weight(.semibold))
                    } else {
                        Text("library.activity.unrated").font(.subheadline)
                    }
                }
                .fixedSize()
            }

            if let lastPlayed = activity.lastPlayed {
                Divider()
                HStack {
                    Label("library.activity.lastPlayed", systemImage: "calendar")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(lastPlayed, style: .date).font(.caption)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }
}

// MARK: - Forms & Popovers

extension LibraryGameSheet {
    var coverTunePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("library.detail.tuneCover").font(.headline)
            Divider()
            coverOptionsForm
        }
        .padding(16)
        .frame(width: 260)
    }

    var coverOptionsForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("library.details.blurredBackground", isOn: $blurredDetailBackground)
                .help("library.details.blurredBackground.help")

            Toggle("library.cover.custom", isOn: $coverSettings.useCustomCover)
                .disabled(store.customCoverURL(for: coverSettings) == nil)
                .onChange(of: coverSettings.useCustomCover) { persistCoverSettings() }

            Button("library.cover.choose") { chooseCover() }
                .disabled(saving)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("library.cover.zoom").font(.caption)
                    Spacer()
                    Text(String(format: "%.1fx", coverSettings.zoom)).font(.caption).monospacedDigit()
                }
                Slider(value: $coverSettings.zoom, in: 1 ... 1.3, onEditingChanged: { editing in
                    if !editing { persistCoverSettings() }
                })
                .accessibilityLabel(Text("library.cover.zoom"))
            }

            if coverSettings.zoom > 1 {
                VStack(alignment: .leading, spacing: 4) {
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
            }

            Button("library.cover.reset") {
                coverSettings.zoom = 1
                coverSettings.horizontalPosition = 0.5
                coverSettings.verticalPosition = 0.5
                persistCoverSettings()
            }
            .controlSize(.small)
        }
    }

    var metadataSearchForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("library.metadata.query", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { startSearch() }
                Button("library.metadata.search") { startSearch() }
                    .disabled(searching || enabled.isEmpty
                        || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if searching {
                    ProgressView().controlSize(.small)
                    Button("button.cancel") {
                        searchTask?.cancel()
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
                Text(result.source.title).font(.headline).padding(.top, 4)
                if let error = result.error {
                    Text(error).foregroundStyle(.secondary)
                } else if result.games.isEmpty {
                    Text("library.metadata.empty").foregroundStyle(.secondary)
                }
                ForEach(FolderGameMatching.ranked(query: query, games: result.games)) { candidate in
                    HStack(alignment: .top, spacing: 10) {
                        cover(candidate.thumbnailURL ?? candidate.coverURL).frame(width: 48, height: 68)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.title).font(.subheadline.bold())
                            Text(candidate.originalTitle).font(.caption).foregroundStyle(.secondary)
                            Text(candidate.releaseDate).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("library.metadata.use") {
                            Task { await save(candidate) }
                        }
                        .disabled(saving)
                        .controlSize(.small)
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            if metadata != nil {
                Divider().padding(.vertical, 4)
                Button("library.metadata.unlink", role: .destructive) {
                    Task { await unlink() }
                }
                .font(.caption)
            }
        }
    }
}

// MARK: - Actions & Helpers

extension LibraryGameSheet {
    func cover(_ url: URL?) -> some View {
        LibraryMetadataArtwork(url: url, directory: item.metadataDirectory)
    }

    func startSearch() {
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

    func save(_ candidate: GameMetadata) async {
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

    func unlink() async {
        do {
            try await store.remove(for: item.metadataIdentity)
            metadata = nil
            didSave()
        } catch { self.error = error.localizedDescription }
    }

    func setRating(_ rating: Int?) {
        do {
            try GameActivityStore.shared.setRating(rating, for: item)
            activity = try GameActivityStore.shared.load(for: item)
        } catch { self.error = error.localizedDescription }
    }

    var usesDetailBackground: Bool {
        blurredDetailBackground && selectedCoverURL != nil
    }

    var selectedCoverURL: URL? {
        if coverSettings.useCustomCover, let url = store.customCoverURL(for: coverSettings) {
            return url
        }
        return metadata?.coverURL
    }

    func persistCoverSettings() {
        let settings = coverSettings
        Task {
            do {
                try await store.saveCoverSettings(settings, for: item.metadataIdentity)
                didSave()
            } catch { self.error = error.localizedDescription }
        }
    }

    func chooseCover() {
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
    var adaptToFrame = true
    var coverAspectRatioDidLoad: (Double) -> Void = { _ in }
    var onHoverCoverChanged: (Bool, URL?, URL) -> Void = { _, _, _ in }
    var coverRevision = 0
    @AppStorage("librarySingleLineTitles") private var singleLineTitles = false
    @State private var coverSettings = GameCoverSettings()
    @State private var isHovered = false

    private var coverURL: URL? {
        let store = GameMetadataStore(directory: item.metadataDirectory)
        if coverSettings.useCustomCover, let url = store.customCoverURL(for: coverSettings) {
            return url
        }
        return metadata?.coverURL
    }

    var body: some View {
        coverButton
            .scaleEffect(isHovered ? 1.03 : 1.0)
            .shadow(
                color: .black.opacity(isHovered ? 0.52 : 0.4),
                radius: isHovered ? 12 : 8,
                x: 0,
                y: isHovered ? 6 : 4
            )
            .zIndex(isHovered ? 2 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                onHoverCoverChanged(hovering, coverURL, item.metadataDirectory)
            }
            .task(id: "\(item.id):\(coverRevision)") {
                coverSettings = await (try? GameMetadataStore(directory: item.metadataDirectory)
                    .loadCoverSettings(for: item.metadataIdentity)) ?? GameCoverSettings()
            }
    }

    private var coverButton: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button(action: details) {
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
                .overlay(alignment: .bottom) {
                    bottomScrimOverlay
                }
                .clipShape(shape)
                .overlay {
                    shape.strokeBorder(.white.opacity(isHovered ? 0.24 : 0.12), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(metadata?.title ?? item.name)
        .accessibilityHint(Text("library.metadata.details"))
        .overlay(alignment: .bottomTrailing) {
            if isHovered || state != .idle {
                playOverlayButton
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .help(metadata?.title ?? item.name)
    }

    private var bottomScrimOverlay: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black.opacity(isHovered ? 0.48 : 0.28), location: 0.45),
                    .init(color: .black.opacity(isHovered ? 0.88 : 0.78), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: isHovered ? 88 : 68)

            VStack(alignment: .leading, spacing: 5) {
                if state != .idle || (isHovered && bottleName != nil) {
                    statusPillRow
                }
                Text(metadata?.title ?? item.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(isHovered ? 1.0 : 0.94))
                    .lineLimit(singleLineTitles ? 1 : 2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.65), radius: 2, x: 0, y: 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 10)
            .padding(.trailing, isHovered || state != .idle ? 44 : 10)
            .padding(.bottom, 9)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var statusPillRow: some View {
        HStack(spacing: 5) {
            if state == .running {
                HStack(spacing: 4) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("library.card.running")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.55), in: Capsule())
            } else if state.isPending {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text(state.phaseLabel).lineLimit(1)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.55), in: Capsule())
            }
            if let bottleName {
                Text(bottleName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.18), in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
                    }
            } else if item.source == .steam {
                Text("library.source.steam")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.18), in: Capsule())
            }
        }
    }

    private var playOverlayButton: some View {
        Button(action: launch) {
            Image(systemName: "play.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.28), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.45), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(state != .idle)
        .accessibilityLabel(Text("button.run"))
        .padding(8)
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "gamecontroller").font(.largeTitle)
            Text(item.name).font(.caption).multilineTextAlignment(.center).lineLimit(2)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.bottom, 28)
    }
}

/// An explicit height uses the whole column span; portrait mode keeps its ratio.
private struct LibraryCoverSurface: View {
    var height: CGFloat?

    var body: some View {
        if let height {
            Rectangle().fill(Color(nsColor: .underPageBackgroundColor))
                .frame(maxWidth: .infinity)
                .frame(height: height)
        } else {
            Rectangle().fill(Color(nsColor: .underPageBackgroundColor))
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
    @State private var cachedAmbient: NSImage?
    @State private var palette: IconPalette = .neutral

    private var localURL: URL? {
        guard let url else { return nil }
        if url.isFileURL {
            return url
        }
        return GameMetadataStore(directory: directory).cachedCoverURL(for: url)
    }

    var body: some View {
        Group {
            if backgroundOnly {
                LibraryDetailBackdrop(ambientImage: cachedAmbient ?? cachedImage)
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
            if let local = localURL {
                guard let sampled = await IconCache.shared.sampledArtwork(for: local),
                      !Task.isCancelled else { return }
                cachedImage = sampled.image
                cachedAmbient = sampled.ambient
                palette = sampled.palette
            } else if let url {
                if let cached = await IconCache.shared.cachedSampledArtwork(for: url) {
                    cachedImage = cached.image
                    cachedAmbient = cached.ambient
                    palette = cached.palette
                    return
                }
                do {
                    try NetworkSettings.requireNetwork()
                    let (data, response) = try await URLSession.shared.data(from: url)
                    guard !Task.isCancelled,
                          let response = response as? HTTPURLResponse,
                          (200 ..< 300).contains(response.statusCode),
                          let sampled = await IconCache.shared.storeSampledArtwork(data: data, for: url),
                          !Task.isCancelled
                    else { return }
                    cachedImage = sampled.image
                    cachedAmbient = sampled.ambient
                    palette = sampled.palette
                } catch {
                    // Keep the placeholder visible until the next load.
                }
            } else {
                cachedImage = nil
                cachedAmbient = nil
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
                        Image(nsImage: cachedAmbient ?? image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                            .frame(width: size.width, height: size.height)
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

/// A semantic scrim preserves readability while delivering multi-hue game artwork ambiance
/// using the pre-blurred `ambientImage` from `IconCache` (zero live GPU `.blur` cost).
private struct LibraryDetailBackdrop: View {
    let ambientImage: NSImage?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .overlay {
                if let ambientImage, !reduceTransparency {
                    Image(nsImage: ambientImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .clipped()
                        .overlay {
                            LinearGradient(
                                stops: [
                                    .init(
                                        color: Color(nsColor: .windowBackgroundColor)
                                            .opacity(colorScheme == .dark ? 0.72 : 0.75),
                                        location: 0
                                    ),
                                    .init(
                                        color: Color(nsColor: .windowBackgroundColor)
                                            .opacity(colorScheme == .dark ? 0.50 : 0.60),
                                        location: 0.35
                                    ),
                                    .init(
                                        color: Color(nsColor: .windowBackgroundColor)
                                            .opacity(colorScheme == .dark ? 0.82 : 0.85),
                                        location: 1.0
                                    )
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                }
            }
    }
}

private struct LibraryDetailReadingPanel: ViewModifier {
    let enabled: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if enabled {
            content
                .padding(14)
                .background {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(reduceTransparency || contrast == .increased
                            ? Color(nsColor: .textBackgroundColor).opacity(0.95)
                            : Color(nsColor: .textBackgroundColor).opacity(colorScheme == .dark ? 0.45 : 0.65))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(
                                    Color.white.opacity(colorScheme == .dark ? 0.12 : 0.25),
                                    lineWidth: 0.5
                                )
                        }
                        .shadow(
                            color: .black.opacity(colorScheme == .dark ? 0.25 : 0.05),
                            radius: 8, x: 0, y: 3
                        )
                }
        } else {
            content
        }
    }
}

/// Isolates hover state from `LibraryView` so moving the pointer across cards
/// never invalidates the grid layout, and debounces lookups into `IconCache`.
@MainActor
final class LibraryAmbientController: ObservableObject {
    @Published private(set) var activeAmbientImage: NSImage?
    private var hoveredID: String?
    private var debounceTask: Task<Void, Never>?

    func updateHover(hovering: Bool, id: String, url: URL?, directory: URL) {
        if hovering {
            guard hoveredID != id else { return }
            hoveredID = id
            debounceTask?.cancel()
            debounceTask = Task {
                try? await Task.sleep(for: .milliseconds(75))
                guard !Task.isCancelled else { return }
                let ambient = await Self.resolveAmbientImage(url: url, directory: directory)
                guard !Task.isCancelled, self.hoveredID == id else { return }
                withAnimation(.easeInOut(duration: 0.32)) {
                    self.activeAmbientImage = ambient
                }
            }
        } else if hoveredID == id {
            hoveredID = nil
            debounceTask?.cancel()
            debounceTask = Task {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, self.hoveredID == nil else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    self.activeAmbientImage = nil
                }
            }
        }
    }

    private static func resolveAmbientImage(url: URL?, directory: URL) async -> NSImage? {
        guard let url else { return nil }
        let localURL: URL? = if url.isFileURL {
            url
        } else {
            GameMetadataStore(directory: directory).cachedCoverURL(for: url)
        }
        if let localURL, let sampled = await IconCache.shared.sampledArtwork(for: localURL) {
            return sampled.ambient
        }
        if let cached = await IconCache.shared.cachedSampledArtwork(for: url) {
            return cached.ambient
        }
        return nil
    }
}

/// Renders the hovered game's pre-blurred `ambient` cover thumbnail across the window
/// with hardware bilinear filtering — delivering the exact multi-hue blurred cover
/// effect with zero runtime `.blur(...)` shader overhead.
struct LibraryAmbientBackdrop: View {
    @ObservedObject var controller: LibraryAmbientController
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if let ambientImage = controller.activeAmbientImage, !reduceTransparency {
                GeometryReader { geometry in
                    Image(nsImage: ambientImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .opacity(0.14)
                        .mask {
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .black, location: 0.12),
                                    .init(color: .black, location: 0.88),
                                    .init(color: .clear, location: 1.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
                .clipped()
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// An Apple Books-inspired chronicle timeline row that pairs a continuous left
/// date axis with a fixed-width (`200pt`) cover showcase slot so portrait (`2:3`)
/// and landscape (`16:9` / `4:3`) covers align on a single editorial text axis.
struct LibraryTimelineRow<MenuContent: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let item: LibraryEntry
    let metadata: GameMetadata?
    let bottleName: String?
    let lastPlayed: Date?
    let state: LibraryEntryState
    var showsDateHeader: Bool = true
    var isFirstEntry: Bool = false
    var isLastEntry: Bool = false
    let details: () -> Void
    let launch: () -> Void
    var coverAspectRatio: Double?
    var coverAspectRatioDidLoad: (Double) -> Void = { _ in }
    var onHoverCoverChanged: (Bool, URL?, URL) -> Void = { _, _, _ in }
    var coverRevision: Int = 0
    @ViewBuilder let menuContent: () -> MenuContent

    @State private var coverSettings = GameCoverSettings()
    @State private var activity = GameActivity()
    @State private var loadedAspect: Double?
    @State private var isHovered = false

    private var coverURL: URL? {
        let store = GameMetadataStore(directory: item.metadataDirectory)
        if coverSettings.useCustomCover, let url = store.customCoverURL(for: coverSettings) {
            return url
        }
        return metadata?.coverURL
    }

    private var effectiveAspect: Double {
        loadedAspect ?? coverAspectRatio ?? (2.0 / 3.0)
    }

    private var isLandscape: Bool {
        effectiveAspect > 1.05
    }

    private var coverSize: CGSize {
        if isLandscape {
            let clampedHeight = min(max(200.0 / max(effectiveAspect, 1.1), 112), 146)
            return CGSize(width: 200, height: clampedHeight)
        }
        return CGSize(width: 148, height: 218)
    }

    private var effectiveDate: Date? {
        activity.lastPlayed ?? lastPlayed
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            dateColumn
                .frame(width: 76, alignment: .trailing)
                .padding(.trailing, 10)
                .padding(.top, 22)

            timelineAxisColumn
                .frame(width: 20)

            contentCard
                .padding(.leading, 12)
                .padding(.trailing, 16)
                .padding(.vertical, 6)

            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
                isHovered = hovering
            }
            onHoverCoverChanged(hovering, coverURL, item.metadataDirectory)
        }
        .task(id: "\(item.id):\(coverRevision)") {
            coverSettings = await (try? GameMetadataStore(directory: item.metadataDirectory)
                .loadCoverSettings(for: item.metadataIdentity)) ?? GameCoverSettings()
            activity = (try? GameActivityStore.shared.load(for: item)) ?? GameActivity()
        }
    }

    @ViewBuilder
    private var dateColumn: some View {
        if showsDateHeader {
            if let date = effectiveDate {
                let currentYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
                VStack(alignment: .trailing, spacing: 2) {
                    if !currentYear {
                        Text(date.formatted(.dateTime.year()))
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                    Text(date.formatted(.dateTime.month().day()))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("library.timeline.unplayed")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.tertiary)
                    if let release = metadata?.releaseDate, !release.isEmpty {
                        Text(release)
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(.quaternary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var timelineAxisColumn: some View {
        let trackColor = Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.12)
        return VStack(spacing: 0) {
            if isFirstEntry {
                Color.clear.frame(height: 22)
            } else {
                Rectangle()
                    .fill(trackColor)
                    .frame(width: 1.5, height: 22)
            }

            nodeView

            if isLastEntry {
                Color.clear.frame(maxHeight: .infinity)
            } else {
                Rectangle()
                    .fill(trackColor)
                    .frame(width: 1.5)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var nodeView: some View {
        let nodeColor: Color = {
            if state == .running {
                return .green
            } else if isHovered {
                return Color.accentColor
            } else if showsDateHeader {
                return Color.primary.opacity(colorScheme == .dark ? 0.8 : 0.65)
            } else {
                return Color.primary.opacity(colorScheme == .dark ? 0.35 : 0.25)
            }
        }()

        let nodeSize: CGFloat = (showsDateHeader || state == .running) ? 8 : 6

        ZStack {
            Circle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: 14, height: 14)

            Circle()
                .fill(nodeColor)
                .frame(width: nodeSize, height: nodeSize)
                .shadow(color: state == .running ? .green.opacity(0.6) : .clear, radius: 4)
        }
        .frame(width: 14, height: 14)
    }

    private var contentCard: some View {
        HStack(alignment: .top, spacing: 20) {
            coverShowcaseSlot

            editorialColumn

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: 860, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    Color.primary.opacity(
                        colorScheme == .dark
                            ? (isHovered ? 0.08 : 0.03)
                            : (isHovered ? 0.05 : 0.02)
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(
                        colorScheme == .dark
                            ? (isHovered ? 0.14 : 0.06)
                            : (isHovered ? 0.10 : 0.04)
                    ),
                    lineWidth: 1
                )
        )
    }

    private var coverShowcaseSlot: some View {
        let size = coverSize
        let shape = RoundedRectangle(cornerRadius: isLandscape ? 8 : 6, style: .continuous)
        return Button(action: details) {
            ZStack {
                Rectangle()
                    .fill(Color(nsColor: .underPageBackgroundColor))
                if let url = coverURL {
                    LibraryMetadataArtwork(
                        url: url,
                        directory: item.metadataDirectory,
                        settings: coverSettings,
                        adaptToFrame: true,
                        imageDidLoad: { aspect in
                            loadedAspect = aspect
                            coverAspectRatioDidLoad(aspect)
                        }
                    )
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "gamecontroller").font(.title2)
                        Text(item.name).font(.caption2).multilineTextAlignment(.center).lineLimit(2)
                    }
                    .foregroundStyle(.secondary)
                    .padding(10)
                }
            }
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .leading) {
                if !isLandscape {
                    bookSpineCrease
                }
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(.white.opacity(isHovered ? 0.26 : 0.14), lineWidth: 1)
            }
            .shadow(
                color: .black.opacity(isHovered ? 0.55 : 0.42),
                radius: isHovered ? 16 : 11,
                x: 0,
                y: isHovered ? 8 : 5
            )
            .scaleEffect(isHovered ? 1.03 : 1.0)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(metadata?.title ?? item.name)
    }

    private var bookSpineCrease: some View {
        LinearGradient(
            stops: [
                .init(color: .white.opacity(0.22), location: 0.0),
                .init(color: .black.opacity(0.28), location: 0.35),
                .init(color: .white.opacity(0.10), location: 0.65),
                .init(color: .clear, location: 1.0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: 7)
        .allowsHitTesting(false)
    }
}

extension LibraryTimelineRow {
    var editorialColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Button(action: details) {
                    Text(metadata?.title ?? item.name)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)

                if let dev = metadata?.developer, !dev.isEmpty {
                    Text(dev)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(item.source == .steam ? "library.source.steam" : "library.source.local")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            badgeRow

            if let summary = metadata?.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary.opacity(0.85))
                    .lineLimit(3)
                    .lineSpacing(3)
                    .frame(maxWidth: 640, alignment: .leading)
            }

            actionGroupRow
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    var badgeRow: some View {
        HStack(spacing: 8) {
            if let bottleName {
                HStack(spacing: 4) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 9.5))
                    Text(bottleName)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05), in: Capsule())
            }

            if activity.playTime >= 60 {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 9.5))
                    Text(Duration.seconds(activity.playTime).formatted(.units(
                        allowed: [.hours, .minutes], width: .abbreviated
                    )))
                    .monospacedDigit()
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05), in: Capsule())
            }

            if let rating = activity.rating {
                HStack(spacing: 3) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.yellow)
                    Text("\(rating)/10")
                        .monospacedDigit()
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05), in: Capsule())
            }
        }
    }

    var actionGroupRow: some View {
        HStack(spacing: 12) {
            primaryActionPill

            secondaryActionGroup
        }
    }

    @ViewBuilder
    var primaryActionPill: some View {
        if state == .running {
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("library.card.running")
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.green)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.green.opacity(0.14), in: Capsule())
            .overlay {
                Capsule().strokeBorder(.green.opacity(0.35), lineWidth: 1)
            }
        } else if state.isPending {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(state.phaseLabel).lineLimit(1)
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
        } else {
            Button(action: launch) {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text(
                        (effectiveDate != nil || activity.playTime > 0)
                            ? LocalizedStringKey("library.timeline.continuePlay")
                            : LocalizedStringKey("library.timeline.playNow")
                    )
                    .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .background(Color.accentColor, in: Capsule())
                .shadow(color: Color.accentColor.opacity(0.32), radius: 5, x: 0, y: 2)
            }
            .buttonStyle(.plain)
        }
    }

    var secondaryActionGroup: some View {
        HStack(spacing: 6) {
            Menu {
                menuContent()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .background(
                Circle()
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05))
            )
            .overlay(
                Circle()
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )

            Button(action: details) {
                Image(systemName: "info")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .background(
                Circle()
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05))
            )
            .overlay(
                Circle()
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .help("library.metadata.details")
        }
    }
}
