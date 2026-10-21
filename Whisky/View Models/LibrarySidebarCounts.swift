//
//  LibrarySidebarCounts.swift
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

import Foundation
import SwiftUI
import WhiskyKit

/// Directory counts are shared by sidebar rows and the Library badge.
@MainActor
final class LibrarySidebarCounts: ObservableObject {
    static let shared = LibrarySidebarCounts()
    static let didChange = Notification.Name("com.franke.Whisky.libraryCatalogueChanged")
    @Published private(set) var counts: [URL: Int] = [:]
    private struct Input: Equatable, Sendable {
        let url: URL
        let pins: [PinnedProgram]
        let available: Bool
    }

    private var inputs: [URL: Input] = [:]
    private var refreshTask: Task<Void, Never>?

    func refresh(bottles: [Bottle], force: Bool = false) {
        let updated = Dictionary(bottles.map {
            ($0.url, Input(url: $0.url, pins: $0.settings.pins, available: $0.isAvailable))
        }, uniquingKeysWith: { first, _ in first })
        guard force || updated != inputs else { return }
        inputs = updated
        schedule()
    }

    func refresh(bottle: Bottle, force: Bool = false) {
        let input = Input(url: bottle.url, pins: bottle.settings.pins, available: bottle.isAvailable)
        guard force || inputs[bottle.url] != input else { return }
        inputs[bottle.url] = input
        schedule()
    }

    private func schedule() {
        refreshTask?.cancel()
        refreshTask = Task {
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            let snapshot = inputs
            let work = Task.detached(priority: .utility) {
                snapshot.mapValues { Self.count($0) }
            }
            let updated = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled else { return }
            if counts != updated {
                counts = updated
            }
        }
    }

    private nonisolated static func count(_ input: Input) -> Int {
        guard input.available else { return 0 }
        let folders = (try? FolderGameLibrary.load(bottleURL: input.url)) ?? FolderGameLibrary()
        let visibility = (try? LibraryVisibility.load(bottleURL: input.url)) ?? LibraryVisibility()
        let pinned = PinnedLibrarySource.items(inBottleAt: input.url, pins: input.pins)
        let folderEntries = folders.knownFolders.filter { !folders.excludedFolders.contains($0) }.map { key in
            let folder = FolderGameLibrary.url(for: key, bottleURL: input.url)
            return LibraryEntry(
                id: "folder:\(input.url.path):\(key)",
                name: folder.lastPathComponent,
                iconURL: nil,
                bottleURL: input.url,
                source: .folder,
                launch: .program(folder)
            )
        }
        return LibraryCatalogue.merge([pinned, folderEntries]).filter { visibility.includes($0, showHidden: false) }
            .count
    }
}
