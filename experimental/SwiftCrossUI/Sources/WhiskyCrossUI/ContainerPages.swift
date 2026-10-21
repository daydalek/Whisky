//
//  ContainerPages.swift
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

struct ContainerOverview: View {
    let container: WorkspaceContainer
    let refreshID: Int
    let artwork: any ArtworkProviding
    let navigate: @MainActor (WorkspaceRoute) -> Void
    let launch: @MainActor (LibraryEntry) -> Void
    let canLaunch: (LibraryEntry) -> Bool
    let addProgram: @MainActor () -> Void
    let runProgram: @MainActor () -> Void
    @State private var programs: [ContainerProgram] = []
    @State private var message = ""

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        let pins = programs.filter { $0.pinned && $0.available }
                        let width = geometry.size.width.isFinite ? max(240, geometry.size.width - 48) : 800
                        let columns = max(1, min(12, Int(width / 120)))
                        ForEach(0 ..< ((pins.count + columns) / columns), id: \.self) { row in
                            HStack(spacing: 14) {
                                ForEach(0 ..< columns, id: \.self) { column in
                                    let index = row * columns + column
                                    if index < pins.count {
                                        let pin = pins[index]
                                        VStack(spacing: 8) {
                                            ArtworkThumbnail(source: .executable(pin.url), provider: artwork)
                                            WorkspaceButton(pin.name) { launch(pin.entry(in: container.url)) }
                                                .buttonStyle(.plain).disabled(!canLaunch(pin.entry(in: container.url)))
                                            WorkspaceButton("设置") { navigate(.program(pin.url)) }.buttonStyle(.plain)
                                                .font(.system(size: 11)).foregroundColor(WhiskyStyle.secondary)
                                        }.frame(width: 106, height: 110)
                                    } else if index == pins.count {
                                        VStack(spacing: 12) {
                                            Text("+").font(.system(size: 32)).foregroundColor(WhiskyStyle.secondary)
                                            WorkspaceButton("固定程序", action: addProgram).buttonStyle(.plain)
                                        }.frame(width: 106, height: 110)
                                    } else {
                                        Spacer().frame(width: 106)
                                    }
                                }
                            }
                        }
                        VStack(spacing: 0) {
                            navigationRow("☷", "已安装的程序", .programs)
                            Color.gray.opacity(0.15).frame(height: 1)
                            navigationRow("⚙", "容器配置", .configuration)
                            Color.gray.opacity(0.15).frame(height: 1)
                            navigationRow("◉", "运行中的进程", .processes)
                        }.background(WhiskyStyle.surface).cornerRadius(10)
                        if !message.isEmpty {
                            Text(message).foregroundColor(WhiskyStyle.secondary)
                        }
                    }.padding(24).frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            HStack {
                WhiskyAction("打开 C: 盘") {
                    do {
                        try WorkspaceSystem.open(container.url.appendingPathComponent("drive_c"))
                    } catch {
                        message = error.localizedDescription
                    }
                }
                Spacer()
                WhiskyAction("运行…", prominent: true, action: runProgram)
                    .disabled(!canLaunch(LibraryEntry(
                        id: "probe",
                        name: "",
                        iconURL: nil,
                        bottleURL: container.url,
                        source: .pinned,
                        launch: .program(container.url)
                    )))
            }.padding(16).background(WhiskyStyle.surface)
        }
        .task(id: "\(container.url.path):\(refreshID)") {
            do { programs = try await ConfigurationFile(
                url: container.url.appendingPathComponent("Metadata.plist"),
                locking: WorkspaceFileLock()
            ).programs(in: container.url) } catch { message = error.localizedDescription }
        }
    }

    private func navigationRow(_ icon: String, _ title: String, _ route: WorkspaceRoute) -> some View {
        HStack {
            Text(icon).frame(width: 28)
            WorkspaceButton(title) { navigate(route) }.buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
            WorkspaceButton("›") { navigate(route) }.buttonStyle(.plain)
        }.padding(16)
    }
}

struct ContainerProgramsView: View {
    let container: WorkspaceContainer
    let refreshID: Int
    let artwork: any ArtworkProviding
    let settings: @MainActor (URL) -> Void
    let changed: @MainActor () async -> Void
    @State private var programs: [ContainerProgram] = []
    @State private var showBlocked = false
    @State private var query = ""
    @State private var busy = false
    @State private var message = ""

    private var store: ConfigurationFile {
        ConfigurationFile(url: container.url.appendingPathComponent("Metadata.plist"), locking: WorkspaceFileLock())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                TextField("搜索程序", text: $query).frame(width: 280)
                Toggle("显示隐藏程序", isOn: $showBlocked)
                Spacer()
                WhiskyAction("扫描程序") { Task { await load() } }.disabled(busy)
            }.padding(18)
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(programs
                        .filter {
                            (showBlocked || !$0.blocked) &&
                                (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
                        }) { program in
                            HStack(spacing: 14) {
                                ArtworkThumbnail(source: .executable(program.url), provider: artwork)
                                VStack(alignment: .leading, spacing: 4) {
                                    WorkspaceButton(program.name) { settings(program.url) }.buttonStyle(.plain)
                                    Text(program.url.path).font(.system(size: 10))
                                        .foregroundColor(WhiskyStyle.secondary)
                                        .lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if !program.available {
                                    WhiskyBadge(text: "文件离线")
                                }
                                WhiskyAction(program.pinned ? "取消固定" : "固定") {
                                    Task { await edit { try await store.setPinned(
                                        !program.pinned,
                                        executable: program.url,
                                        name: program.name
                                    ) } }
                                }
                                WhiskyAction(program.blocked ? "恢复显示" : "隐藏") {
                                    Task {
                                        await edit { try await store.setBlocked(
                                            !program.blocked,
                                            executable: program.url
                                        )
                                        }
                                    }
                                }
                                WhiskyAction("设置") { settings(program.url) }
                            }.padding(12).background(WhiskyStyle.surface).disabled(busy)
                        }
                    if programs.isEmpty {
                        Text(busy ? "正在扫描程序…" : "C: 盘中暂无已安装程序").padding(40)
                    }
                }.padding(.horizontal, 18)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Text(message).font(.system(size: 11)).foregroundColor(WhiskyStyle.secondary).padding(12)
        }.task(id: "\(container.url.path):\(refreshID)") { await load() }
    }

    private func load() async {
        busy = true
        defer { busy = false }
        do {
            programs = try await store.programs(in: container.url)
        } catch {
            message = error.localizedDescription
        }
    }

    private func edit(_ operation: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        do {
            try await operation()
            WorkspaceHost.invalidate(container.url)
            await changed()
            message = "已保存"
        } catch { message = error.localizedDescription }
        await load()
    }
}

struct ProgramSettingsPage: View {
    let executable: URL
    let container: WorkspaceContainer
    let refreshID: Int
    let launch: @MainActor () -> Void
    let canLaunch: Bool
    @State private var variables: [String: String] = [:]
    @State private var name = ""
    @State private var value = ""
    @State private var message = ""
    @State private var busy = false

    private var store: ConfigurationFile {
        let paths = ProgramStorageLayout.locations(for: executable, containerURL: container.url)
        return ConfigurationFile(url: paths.identity, locking: WorkspaceFileLock(), fallbackURL: paths.legacy)
    }

    private var sections: [ConfigurationSection] {
        ContainerConfiguration.programSections
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(executable.lastPathComponent).font(.system(size: 22, weight: .semibold))
                    Text(executable.path).font(.system(size: 11)).foregroundColor(WhiskyStyle.secondary)
                    ConfigurationEditor(
                        file: store,
                        sections: sections,
                        refreshID: refreshID,
                        changed: { await reloadVariables() }
                    )
                    VStack(alignment: .leading, spacing: 12) {
                        Text("环境变量").font(.system(size: 14, weight: .semibold))
                        ForEach(variables.keys.sorted(), id: \.self) { key in
                            HStack(spacing: 14) {
                                Text(key).frame(width: 180, alignment: .leading)
                                Text(variables[key] ?? "").frame(maxWidth: .infinity, alignment: .leading)
                                WhiskyAction("编辑") { name = key
                                    value = variables[key] ?? ""
                                }
                                WhiskyAction("移除") { Task { await saveVariable(key, value: nil) } }
                            }
                        }
                        HStack(spacing: 10) {
                            TextField("名称", text: $name).frame(width: 180)
                            TextField("值", text: $value).frame(maxWidth: .infinity)
                            WhiskyAction("保存变量") { Task { await saveVariable(name, value: value) } }
                                .disabled(name.isEmpty)
                        }
                        if !message.isEmpty {
                            Text(message).foregroundColor(WhiskyStyle.secondary)
                        }
                    }.padding(16).background(WhiskyStyle.surface).cornerRadius(10).disabled(busy)
                }.padding(24).frame(maxWidth: .infinity, alignment: .topLeading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                Spacer()
                WhiskyAction("显示文件") {
                    do {
                        try WorkspaceSystem.show(executable)
                    } catch {
                        message = error.localizedDescription
                    }
                }
                WhiskyAction("运行", prominent: true, action: launch).disabled(!canLaunch)
            }.padding(16).background(WhiskyStyle.surface)
        }.task(id: executable) { await reloadVariables() }
    }

    private func reloadVariables() async {
        do {
            variables = try await store.strings(at: "environment")
        } catch {
            message = error.localizedDescription
        }
    }

    private func saveVariable(_ key: String, value: String?) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await store.setEnvironmentVariable(key, value: value)
            name = ""
            self.value = ""
            message = "已保存"
            await reloadVariables()
        } catch { message = "保存失败：\(error.localizedDescription)" }
    }
}
