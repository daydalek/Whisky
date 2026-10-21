//
//  WorkspaceView.swift
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
import SwiftCrossUI
import WhiskyCore

struct WorkspaceView: View {
    let runtime: any LibraryRuntime
    let artwork: any ArtworkProviding
    let directoryPicker: (any DirectoryPicking)?
    @State private var state = WorkspaceState()
    @State private var showsDetail = false
    @Environment(\.chooseFile) private var chooseFile

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Color.gray.opacity(0.18).frame(width: 1)
            VStack(spacing: 0) {
                toolbar
                Color.gray.opacity(0.15).frame(height: 1)
                content
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity, alignment: .topLeading)
        .background(WhiskyStyle.background)
        .sheet(isPresented: $showsDetail) {
            if let game = state.selectedGame {
                WorkspaceGameDetail(
                    game: game,
                    artwork: artwork,
                    dismiss: { showsDetail = false },
                    launch: { Task { await launch(game.item) } },
                    canLaunch: runtime.capabilities(for: game.item).contains(.launch),
                    changed: { await reload() }
                )
            }
        }
        .task { await reload() }
        .task {
            for await event in runtime.events() {
                guard !Task.isCancelled else { return }
                switch event {
                case let .state(updated): state.runtime = updated
                case let .launchResult(_, result):
                    state.message = result.errorDescription ?? "已发送启动请求：\(result.programName)"
                case let .failure(failure):
                    state.message = String(describing: failure)
                }
            }
        }
        .onDisappear { runtime.stopTracking() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Whisky").font(.system(size: 20, weight: .semibold)).padding(.bottom, 18)
            WorkspaceButton("▦  游戏库    \(state.snapshot.games.filter { !$0.hidden }.count)") {
                state.selectedContainer = nil
                state.route = .library
            }
            .buttonStyle(.plain).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(state.selectedContainer == nil ? WhiskyStyle.selection : .clear).cornerRadius(7)
            Text("容器").font(.system(size: 11, weight: .semibold))
                .foregroundColor(WhiskyStyle.secondary).padding(.top, 18).padding(.leading, 10)
            ForEach(state.snapshot.containers) { container in
                WorkspaceButton("◇  \(container.name)    \(count(for: container.url))") {
                    state.selectedContainer = container.url
                    state.route = container.isPrefix ? .overview : .library
                }
                .buttonStyle(.plain).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(state.selectedContainer == container.url ? WhiskyStyle.selection : .clear)
                .cornerRadius(7).disabled(!container.available)
            }
            Spacer()
            WhiskyAction("打开游戏目录") { Task { await chooseDirectory() } }
                .disabled(state.isLoading)
        }
        .padding(14).frame(width: 220).frame(maxHeight: .infinity, alignment: .topLeading)
        .background(WhiskyStyle.sidebar)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if state.route != .library, state.route != .overview {
                WhiskyAction("‹ 返回") {
                    if case .program = state.route {
                        state.route = .programs
                    } else {
                        state.route = .overview
                    }
                }
            }
            Text(state.snapshot.containers.first { $0.url == state.selectedContainer }?.name ?? "游戏库")
                .font(.system(size: 18, weight: .semibold))
            if state.route != .library, state.route != .overview {
                Text(state.route.title).foregroundColor(WhiskyStyle.secondary)
            }
            Spacer()
            WhiskyAction("刷新") { Task { await reload() } }.disabled(state.isLoading)
            if state.route == .library {
                HStack(spacing: 3) {
                    ForEach(WorkspaceDisplay.allCases, id: \.rawValue) { mode in
                        WhiskyAction(mode.rawValue, selected: state.display == mode) { state.display = mode }
                    }
                }
                Menu("选项") {
                    WorkspaceButton("最近游玩") { state.sort = .recent }
                    WorkspaceButton("名称") { state.sort = .name }
                    WorkspaceButton("容器") { state.sort = .bottle }
                    Toggle("显示隐藏游戏", isOn: $state.showHidden)
                }
                TextField("搜索游戏", text: $state.query).frame(width: 240)
            }
        }
        .padding(16).background(WhiskyStyle.surface)
    }

    @ViewBuilder private var content: some View {
        if let container = state.snapshot.containers.first(where: { $0.url == state.selectedContainer }),
           state.route != .library {
            switch state.route {
            case .overview:
                ContainerOverview(
                    container: container,
                    refreshID: state.refreshID,
                    artwork: artwork,
                    navigate: { state.route = $0 },
                    launch: { entry in Task { await launch(entry) } },
                    canLaunch: { runtime.capabilities(for: $0).contains(.launch) },
                    addProgram: { Task { await chooseProgram(container, pin: true) } },
                    runProgram: { Task { await chooseProgram(container, pin: false) } }
                )
            case .configuration:
                ContainerConfigurationView(
                    container: container,
                    refreshID: state.refreshID,
                    changed: { await reload() }
                )
            case .programs:
                ContainerProgramsView(
                    container: container,
                    refreshID: state.refreshID,
                    artwork: artwork,
                    settings: { state.route = .program($0) },
                    changed: { await reload() }
                )
            case let .program(executable):
                let entry = LibraryEntry(
                    id: "pinned:\(executable.path)",
                    name: executable.lastPathComponent,
                    iconURL: executable,
                    bottleURL: container.url,
                    source: .pinned,
                    launch: .program(executable)
                )
                ProgramSettingsPage(
                    executable: executable,
                    container: container,
                    refreshID: state.refreshID,
                    launch: { Task { await launch(entry) } },
                    canLaunch: runtime.capabilities(for: entry).contains(.launch)
                )
            case .library: library
            case .processes: ContainerProcessesView(container: container, refreshID: state.refreshID)
            }
        } else {
            library
        }
    }

    private var library: some View {
        GeometryReader { geometry in
            ScrollView {
                if state.isLoading, state.snapshot.games.isEmpty {
                    Text("正在读取游戏库…").padding(40)
                } else if state.games.isEmpty {
                    VStack(spacing: 14) {
                        Text(state.query.isEmpty ? "你的游戏库" : "搜索结果为空")
                            .font(.system(size: 26, weight: .semibold))
                        Text(state.query.isEmpty ? "打开现有容器或选择游戏目录，开始浏览游戏。" : "尝试游戏名称或别名。")
                            .foregroundColor(WhiskyStyle.secondary)
                        WhiskyAction("打开游戏目录", prominent: true) { Task { await chooseDirectory() } }
                    }.padding(60).frame(maxWidth: .infinity)
                } else {
                    WorkspaceLibrary(
                        games: state.games,
                        display: state.display,
                        width: geometry.size.width - 40,
                        artwork: artwork,
                        runtime: state.runtime,
                        capabilities: { runtime.capabilities(for: $0) },
                        detail: { state.selectedGame = $0
                            showsDetail = true
                        },
                        launch: { game in Task { await launch(game.item) } },
                        cancel: { runtime.cancelLaunch(for: $0.item) },
                        stop: { game in Task { await runtime.stop(game.item) } }
                    )
                    .padding(20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var footer: some View {
        HStack {
            Text(state.isLoading ? "读取中…" : "\(state.games.count) 个游戏")
            Spacer()
            Text(state.message).lineLimit(1)
        }
        .font(.system(size: 11)).foregroundColor(WhiskyStyle.secondary)
        .padding(.horizontal, 18).padding(.vertical, 8)
    }

    private func count(for url: URL) -> Int {
        state.snapshot.games.filter { $0.item.bottleURL == url && !$0.hidden }.count
    }
}

private extension WorkspaceView {
    func reload() async {
        guard !state.isLoading else { return }
        state.isLoading = true
        defer { state.isLoading = false }
        let roots = state.addedRoots
        do {
            let snapshot = try await Task.detached { try WorkspaceSnapshot.load(extraRoots: roots) }.value
            guard !Task.isCancelled else { return }
            state.snapshot = snapshot
            state.refreshID += 1
            state.message = snapshot.warnings.first ?? ""
            WorkspaceHost.refresh(Set(snapshot.containers.filter(\.available).map(\.url)))
            runtime.retainContainers(Set(snapshot.containers.filter(\.available).map(\.url)))
            for container in snapshot.containers where container.available {
                await runtime.configure(
                    entries: snapshot.games.filter { $0.item.bottleURL == container.url }.map(\.item),
                    containerURL: container.url
                )
            }
        } catch { state.message = error.localizedDescription }
    }

    private func chooseDirectory() async {
        let root: URL? = if let directoryPicker {
            await directoryPicker.chooseDirectory(initialDirectory: nil)
        } else {
            await chooseFile(
                title: "选择包含游戏文件夹的目录",
                allowSelectingFiles: false,
                allowSelectingDirectories: true
            )
        }
        guard let root else { return }
        if !state.addedRoots.contains(root) {
            state.addedRoots.append(root)
        }
        state.selectedContainer = root.standardizedFileURL
        await reload()
        state.route = state.snapshot.containers.first(where: { $0.url == root.standardizedFileURL })?
            .isPrefix == true ? .overview : .library
    }

    private func chooseProgram(_ container: WorkspaceContainer, pin: Bool) async {
        guard let executable = await chooseFile(
            title: "选择 Windows EXE",
            initialDirectory: container.url.appendingPathComponent("drive_c")
        )
        else { return }
        guard executable.pathExtension.lowercased() == "exe" else { state.message = "请选择 Windows EXE 文件"
            return
        }
        if !pin {
            let entry = LibraryEntry(
                id: "pinned:\(executable.path)",
                name: executable.lastPathComponent,
                iconURL: executable,
                bottleURL: container.url,
                source: .pinned,
                launch: .program(executable)
            )
            await launch(entry)
            return
        }
        do {
            let store = ConfigurationFile(
                url: container.url.appendingPathComponent("Metadata.plist"),
                locking: WorkspaceFileLock()
            )
            try await store.setPinned(
                true,
                executable: executable,
                name: executable.deletingPathExtension().lastPathComponent
            )
            WorkspaceHost.invalidate(container.url)
            await reload()
            state.route = .program(executable)
        } catch { state.message = error.localizedDescription }
    }

    private func launch(_ entry: LibraryEntry) async {
        var executable: URL?
        if entry.source == .folder {
            do {
                let picker = ClosureExecutablePicker { directory in
                    await chooseFile(title: "选择 Windows EXE", initialDirectory: directory)
                }
                executable = try await FolderGameLibrary.resolveExecutable(for: entry, picker: picker)
                guard executable != nil else { return }
            } catch {
                state.message = error.localizedDescription
                return
            }
        }
        runtime.launch(LibraryLaunchRequest(entry: entry, executableURL: executable))
    }
}
