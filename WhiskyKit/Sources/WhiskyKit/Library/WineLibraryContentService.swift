//
//  WineLibraryContentService.swift
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

import Foundation
import WhiskyCore

/// Adapts native container settings, metadata and records to shared library commands.
@MainActor
public final class WineLibraryContentService: LibraryContentProviding {
    public typealias BottleResolver = @MainActor (URL) -> Bottle?
    private let bottleResolver: BottleResolver
    private let store: GameActivityStore

    public init(
        bottleResolver: @escaping BottleResolver = { _ in nil }, store: GameActivityStore = .shared
    ) {
        self.bottleResolver = bottleResolver
        self.store = store
    }

    public func discover(in containerURL: URL) async throws -> LibraryDiscovery {
        try await Task.detached {
            let steam = SteamLibrarySource.entries(inBottleAt: containerURL)
            let folders = try FolderGameLibrary.load(bottleURL: containerURL)
            let exclusions = SteamLibrary.enumerate(bottleURL: containerURL).map(\.installURL)
                + [SteamLibrary.detectInstall(bottleURL: containerURL)].compactMap { $0 }
            return LibraryDiscovery.scan(
                in: containerURL,
                folders: folders,
                additionalEntries: steam,
                excluding: exclusions
            )
        }.value
    }

    public func commit(_ discovery: LibraryDiscovery) throws {
        var current = try FolderGameLibrary.load(bottleURL: discovery.containerURL)
        if discovery.apply(to: &current) {
            try current.save(bottleURL: discovery.containerURL)
        }
    }

    public func visibility(in containerURL: URL) throws -> LibraryVisibility {
        try LibraryVisibility.load(bottleURL: containerURL)
    }

    public func setHidden(_ hidden: Bool, for entry: LibraryEntry) throws -> LibraryVisibility {
        var visibility = try visibility(in: entry.bottleURL)
        visibility.setHidden(hidden, for: entry)
        try visibility.save(bottleURL: entry.bottleURL)
        return visibility
    }

    public func activity(for entry: LibraryEntry) throws -> GameActivity {
        try store.load(for: entry)
    }

    public func activities(for entries: [LibraryEntry]) async throws -> [String: GameActivity] {
        try await store.perform { store in
            Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
                guard let activity = try? store.load(for: entry) else { return nil }
                return (entry.id, activity)
            })
        }
    }

    public func move(_ entry: LibraryEntry, to containerURL: URL, hidden: Bool) async throws -> LibraryEntry {
        guard case let .program(url) = entry.launch, entry.bottleURL != containerURL,
              let target = bottleResolver(containerURL)
        else { throw CocoaError(.fileNoSuchFile) }
        let moved = LibraryEntry(
            id: entry.id, name: entry.name, iconURL: entry.iconURL, artworkURL: entry.artworkURL,
            bottleURL: containerURL, source: entry.source, launch: entry.launch, launcher: entry.launcher
        )
        if entry.source == .folder {
            try FolderGameLibrary.moveFolder(url, from: entry.bottleURL, to: containerURL)
        } else {
            transferPin(entry, executable: url, to: target)
        }
        let sourceStore = GameMetadataStore(directory: entry.metadataDirectory)
        let targetStore = GameMetadataStore(directory: moved.metadataDirectory)
        try await sourceStore.copyEntry(
            for: entry.metadataIdentity, to: targetStore, targetIdentity: moved.metadataIdentity
        )
        try await store.perform { try $0.copy(from: entry, to: moved) }
        _ = try setHidden(hidden, for: moved)
        return moved
    }

    private func transferPin(_ entry: LibraryEntry, executable: URL, to target: Bottle) {
        FolderGameLibrary.migrateProgramSettings(for: executable, from: entry.bottleURL, to: target.url)
        if let source = bottleResolver(entry.bottleURL) {
            source.settings.pins.removeAll { $0.url == executable }
            if let program = source.programs.first(where: { $0.url == executable }) {
                program.pinned = false
            }
        }
        if !target.settings.pins.contains(where: { $0.url == executable }) {
            target.settings.pins.append(PinnedProgram(name: entry.name, url: executable))
        }
        if let program = target.programs.first(where: { $0.url == executable }) {
            program.pinned = true
        } else {
            let program = Program(url: executable, bottle: target)
            program.pinned = true
            target.programs.append(program)
        }
    }
}
