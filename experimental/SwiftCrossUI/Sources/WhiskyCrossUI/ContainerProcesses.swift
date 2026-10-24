//
//  ContainerProcesses.swift
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
#if os(macOS)
import WhiskyKit
#endif

struct WorkspaceProcess: Identifiable, Sendable {
    let id: Int32
    let name: String
    let memory: String
    let kind: String
}

extension WorkspaceHost {
    static var supportsProcesses: Bool {
        #if os(macOS)
        !ProcessInfo.processInfo.arguments.contains("--browse-only")
        #else
        false
        #endif
    }

    static func processes(in container: URL) async throws -> [WorkspaceProcess] {
        #if os(macOS)
        guard supportsProcesses, let bottle = bottle(at: container) else { throw CocoaError(.featureUnsupported) }
        return try await Wine.listProcesses(for: bottle).map {
            WorkspaceProcess(
                id: $0.winePID,
                name: $0.imageName,
                memory: $0.memoryUsage,
                kind: String(describing: $0.kind)
            )
        }
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }

    static func terminate(_ process: WorkspaceProcess?, in container: URL, force: Bool) async throws {
        #if os(macOS)
        guard supportsProcesses, let bottle = bottle(at: container) else { throw CocoaError(.featureUnsupported) }
        let stream: AsyncStream<ProcessOutput>
        if let process {
            guard try await processes(in: container).contains(where: { $0.id == process.id && $0.name == process.name })
            else { return }
            var args = ["taskkill.exe", "/PID", String(process.id)]
            if force {
                args.append("/F")
            }
            stream = try Wine.runWineProcess(args: args, bottle: bottle)
        } else {
            stream = try Wine.runWineserverProcess(args: ["-k"], bottle: bottle)
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in stream {
                    guard !Task.isCancelled else { throw CancellationError() }
                    if case let .terminated(code) = event {
                        guard code == 0 else { throw ProcessCommandError.exit(code) }
                        return
                    }
                }
                throw CocoaError(.executableRuntimeMismatch)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw ProcessCommandError.timeout
            }
            defer { group.cancelAll() }
            try await group.next()
        }
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }
}

private enum ProcessCommandError: LocalizedError {
    case exit(Int32)
    case timeout
    var errorDescription: String? {
        switch self {
        case let .exit(code): "进程操作失败，退出码：\(code)"
        case .timeout: "进程操作等待超时，请刷新进程状态"
        }
    }
}

struct ContainerProcessesView: View {
    let container: WorkspaceContainer
    let refreshID: Int
    @State private var processes: [WorkspaceProcess] = []
    @State private var busy = false
    @State private var loaded = false
    @State private var message = ""
    @State private var query = ""
    @State private var selected: WorkspaceProcess?
    @State private var confirm = false
    @State private var force = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                TextField("搜索进程", text: $query).frame(width: 280)
                Spacer()
                WhiskyAction("刷新进程") { Task { await refresh() } }.disabled(busy || !WorkspaceHost.supportsProcesses)
                WhiskyAction("结束容器进程") { selected = nil
                    force = true
                    confirm = true
                }
                .disabled(busy || processes.isEmpty)
            }
            if WorkspaceHost.supportsProcesses {
                if confirm {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(selected.map { "结束 \($0.name)（PID \($0.id)）？" } ?? "结束此容器中的所有进程？")
                            .font(.system(size: 14, weight: .semibold))
                        Text("请先保存运行中程序的内容。").foregroundColor(WhiskyStyle.secondary)
                        HStack {
                            WhiskyAction("取消") { confirm = false }
                            WhiskyAction(force ? "强制结束" : "结束", prominent: true) {
                                Task { await terminateSelection() }
                            }
                        }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(WhiskyStyle.surface).cornerRadius(10).disabled(busy)
                }
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(processes
                            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { process in
                                HStack(spacing: 16) {
                                    Text(process.name).frame(maxWidth: .infinity, alignment: .leading)
                                    Text("PID \(process.id)").frame(width: 100, alignment: .leading)
                                    Text(process.memory).frame(width: 100, alignment: .leading)
                                    WhiskyBadge(text: process.kind)
                                    WhiskyAction("结束") { selected = process
                                        force = false
                                        confirm = true
                                    }
                                    WhiskyAction("强制结束") { selected = process
                                        force = true
                                        confirm = true
                                    }
                                }.padding(14).background(WhiskyStyle.surface).disabled(busy)
                            }
                        if loaded, processes.isEmpty {
                            Text("当前容器暂无运行中的进程").padding(40)
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Text("此平台提供容器与程序配置；Wine 进程管理在 macOS 运行时中使用。")
                    .foregroundColor(WhiskyStyle.secondary).padding(.vertical, 30)
                Spacer()
            }
            Text(busy ? "正在读取进程…" : message).font(.system(size: 11)).foregroundColor(WhiskyStyle.secondary)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .task(id: "\(container.url.path):\(refreshID)") {
                if WorkspaceHost.supportsProcesses {
                    await refresh()
                }
            }
    }

    private func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let latest = try await WorkspaceHost.processes(in: container.url)
            guard !Task.isCancelled else { return }
            processes = latest
            loaded = true
            message = "\(latest.count) 个进程"
        } catch { message = error.localizedDescription }
    }

    private func terminateSelection() async {
        guard !busy else { return }
        busy = true
        var failure: String?
        do {
            try await WorkspaceHost.terminate(selected, in: container.url, force: force)
            confirm = false
            message = "结束命令已执行"
        } catch { failure = error.localizedDescription }
        busy = false
        await refresh()
        if let failure {
            message = failure
        }
    }
}
