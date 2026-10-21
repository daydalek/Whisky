//
//  Workspace.swift
//  WhiskyCrossUI
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
import WhiskyApplication
import WhiskyCore

struct WorkspaceContainer: Identifiable, Sendable {
    let url: URL
    let name: String
    let available: Bool
    var isPrefix: Bool = false
    var id: URL {
        url
    }
}

struct WorkspaceGame: Identifiable, LibrarySortableRow, Sendable {
    let item: LibraryEntry
    let containerName: String
    let presentation: LibraryPresentation
    let hidden: Bool

    var id: String {
        item.id
    }

    var bottleName: String? {
        containerName
    }

    var lastSessionEndedAt: Date? {
        presentation.activity.lastSessionEndedAt
    }

    var title: String {
        presentation.metadata?.title ?? item.name
    }

    var artwork: ArtworkSource? {
        (presentation.coverURL ?? presentation.metadata?.coverURL).map(ArtworkSource.image) ?? item.artworkSource
    }
}

struct WorkspaceSnapshot: Sendable {
    let containers: [WorkspaceContainer]
    let games: [WorkspaceGame]
    let warnings: [String]

    /// Registry reads preserve corrupt files so the native app can offer recovery.
    static func registryURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        HostPaths.registry(environment: environment)
    }

    static func load(arguments: [String] = ProcessInfo.processInfo.arguments, extraRoots: [URL] = []) throws -> Self {
        struct Registry: Decodable { let paths: [URL] }
        let explicit = argument("--bottle", in: arguments).map { URL(fileURLWithPath: $0, isDirectory: true) }
        let registry = argument("--registry", in: arguments).map { URL(fileURLWithPath: $0) } ?? registryURL()
        var roots: [URL] = []
        if let explicit {
            roots = [explicit]
        } else if FileManager.default.fileExists(atPath: registry.path) {
            roots = try PropertyListDecoder().decode(Registry.self, from: Data(contentsOf: registry)).paths
        }
        roots += extraRoots
        var seen = Set<URL>()
        roots = roots.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
        var containers: [WorkspaceContainer] = []
        var games: [WorkspaceGame] = []
        var warnings: [String] = []
        for root in roots {
            let available = (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let metadata = root.appendingPathComponent("Metadata.plist")
            let name = (try? PropertyListDecoder().decode(
                WorkspaceContainerInfo.self, from: Data(contentsOf: metadata)
            ).info.name) ?? root.lastPathComponent
            containers.append(WorkspaceContainer(
                url: root,
                name: name,
                available: available,
                isPrefix: FileManager.default.fileExists(atPath: metadata.path)
            ))
            guard available else { continue }
            games += scan(root: root, name: name, metadata: metadata, warnings: &warnings)
        }
        return Self(
            containers: containers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            games: games,
            warnings: warnings
        )
    }

    private static func scan(root: URL, name: String, metadata: URL, warnings: inout [String]) -> [WorkspaceGame] {
        var games: [WorkspaceGame] = []
        do {
            let hasConfiguration = FileManager.default.fileExists(atPath: metadata.path)
                || FileManager.default.fileExists(atPath: root.appendingPathComponent("Folder Games.json").path)
            let entries = try readBrowserEntries(
                root: hasConfiguration ? nil : root,
                bottle: hasConfiguration ? root : nil,
                includingHidden: true
            )
            let visibility = try LibraryVisibility.load(bottleURL: root)
            for entry in entries {
                let presentation: LibraryPresentation
                do {
                    presentation = try .load(for: entry)
                } catch {
                    warnings.append("\(entry.name)：\(error.localizedDescription)")
                    presentation = LibraryPresentation()
                }
                games.append(WorkspaceGame(
                    item: entry,
                    containerName: name,
                    presentation: presentation,
                    hidden: !visibility.includes(entry)
                ))
            }
        } catch { warnings.append("\(name)：\(error.localizedDescription)") }
        return games
    }

    private static func argument(_ option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

enum WorkspaceDisplay: String, CaseIterable {
    case shelf = "书架", timeline = "时间线", cards = "经典卡片"
}

enum WorkspaceRoute: Equatable {
    case library, overview, configuration, programs, processes, program(URL)
    var title: String {
        switch self {
        case .library: "游戏库"
        case .overview: "容器"
        case .configuration: "容器配置"
        case .programs: "已安装的程序"
        case .processes: "运行中的进程"
        case .program: "程序设置"
        }
    }
}

struct WorkspaceState {
    var route = WorkspaceRoute.library
    var refreshID = 0
    var snapshot = WorkspaceSnapshot(containers: [], games: [], warnings: [])
    var selectedContainer: URL?
    var query = ""
    var display = WorkspaceDisplay.timeline
    var sort = LibrarySort.recent
    var showHidden = false
    var selectedGame: WorkspaceGame?
    var message = ""
    var isLoading = false
    var addedRoots: [URL] = []
    var runtime = LibraryRuntimeState()

    var games: [WorkspaceGame] {
        let filtered = snapshot.games.filter {
            (selectedContainer == nil || $0.item.bottleURL == selectedContainer)
                && (showHidden || !$0.hidden)
                && (query.isEmpty || ([$0.item.name, $0.title] + ($0.presentation.metadata?.matchingTitles ?? []))
                    .contains { $0.localizedCaseInsensitiveContains(query) })
        }
        return LibraryOrdering.sorted(
            filtered,
            by: display == .timeline ? sort : .name,
            groupsLaunchers: display != .timeline
        )
    }
}

private struct WorkspaceContainerInfo: Decodable {
    struct Info: Decodable { let name: String }
    let info: Info
}
