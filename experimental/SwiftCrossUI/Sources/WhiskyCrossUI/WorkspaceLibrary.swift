//
//  WorkspaceLibrary.swift
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

struct WorkspaceLibrary: View {
    let games: [WorkspaceGame]
    let display: WorkspaceDisplay
    let width: Double
    let artwork: any ArtworkProviding
    let runtime: LibraryRuntimeState
    let capabilities: (LibraryEntry) -> LibraryRuntimeCapabilities
    let detail: (WorkspaceGame) -> Void
    let launch: (WorkspaceGame) -> Void
    let cancel: (WorkspaceGame) -> Void
    let stop: (WorkspaceGame) -> Void

    var body: some View {
        switch display {
        case .timeline:
            VStack(spacing: 16) {
                ForEach(games) { game in
                    HStack(spacing: 18) {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(game.lastSessionEndedAt == nil ? "尚未游玩" : "上次游玩结束")
                                .font(.system(size: 10)).foregroundColor(WhiskyStyle.secondary)
                            if let date = game.lastSessionEndedAt {
                                Text(date.formatted(.dateTime.month().day())).font(.system(size: 14, weight: .medium))
                            }
                        }.frame(width: 100, alignment: .trailing)
                        timelineCard(game)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .topLeading)
        case .shelf:
            shelf
        case .cards:
            classicCards
        }
    }

    private func timelineCard(_ game: WorkspaceGame) -> some View {
        HStack(spacing: 22) {
            CoverArtwork(
                source: game.artwork,
                provider: artwork,
                width: 148,
                height: 222,
                cacheDirectory: game.item.metadataDirectory
            )
            .cornerRadius(7)
            .onTapGesture { detail(game) }
            VStack(alignment: .leading, spacing: 10) {
                WorkspaceButton(game.title) { detail(game) }.buttonStyle(.plain)
                    .font(.system(size: 22, weight: .bold)).lineLimit(2)
                if let metadata = game.presentation.metadata, !metadata.developer.isEmpty {
                    Text(metadata.developer).font(.system(size: 12)).foregroundColor(WhiskyStyle.secondary)
                }
                HStack(spacing: 6) {
                    WhiskyBadge(text: "◇ " + game.containerName)
                    if game.presentation.activity.playTime >= 60 {
                        WhiskyBadge(text: playTime(game.presentation.activity.playTime))
                    }
                    if let rating = game.presentation.activity.rating {
                        WhiskyBadge(text: "★ \(rating)/10")
                    }
                }
                if let summary = game.presentation.metadata?.summary, !summary.isEmpty {
                    Text(summary).font(.system(size: 12)).foregroundColor(WhiskyStyle.secondary).lineLimit(4)
                }
                if runtime.launch.state(for: game.item) != .idle {
                    Text(status(game)).font(.system(size: 11)).foregroundColor(WhiskyStyle.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 12) {
                actions(game)
                WhiskyAction("详情") { detail(game) }
            }.frame(width: 110)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(WhiskyStyle.surface).cornerRadius(14)
    }

    private var shelf: some View {
        let layout = LibraryCoverGrid(width: width, landscape: games.map {
            ($0.presentation.coverAspectRatio ?? 2.0 / 3) > 1.15
        })
        return VStack(alignment: .leading, spacing: 20) {
            ForEach(Array(layout.rows.indices), id: \.self) { row in
                HStack(alignment: .top, spacing: 12) {
                    ForEach(layout.rows[row], id: \.self) { index in
                        let coverWidth = layout.columnWidth * Double(layout.spans[index])
                            + Double(layout.spans[index] - 1) * layout.spacing
                        VStack(alignment: .leading, spacing: 8) {
                            CoverArtwork(
                                source: games[index].artwork,
                                provider: artwork,
                                width: coverWidth,
                                height: layout.coverHeight,
                                cacheDirectory: games[index].item.metadataDirectory
                            )
                            .cornerRadius(8).onTapGesture { detail(games[index]) }
                            WorkspaceButton(games[index].title) { detail(games[index]) }
                                .buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                            Text(games[index].containerName).font(.system(size: 11))
                                .foregroundColor(WhiskyStyle.secondary)
                            actions(games[index])
                        }.frame(width: coverWidth, alignment: .topLeading)
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var classicCards: some View {
        let available = width.isFinite ? max(240, min(width, 16_384)) : 900
        let columns = max(1, Int(available / 280))
        let rows = (games.count + columns - 1) / columns
        let columnWidth = max(240, (available - Double(columns - 1) * 14) / Double(columns))
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(0 ..< rows), id: \.self) { row in
                HStack(alignment: .top, spacing: 14) {
                    ForEach(Array((row * columns) ..< min((row + 1) * columns, games.count)), id: \.self) { index in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                CoverArtwork(
                                    source: games[index].item.artworkSource,
                                    provider: artwork,
                                    width: 48,
                                    height: 48
                                )
                                WorkspaceButton(games[index].item.name) { detail(games[index]) }
                                    .buttonStyle(.plain).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                            }
                            Text(games[index].containerName).font(.system(size: 11))
                                .foregroundColor(WhiskyStyle.secondary)
                            HStack { Text(status(games[index])).font(.system(size: 11))
                                Spacer()
                                actions(games[index])
                            }
                        }
                        .padding(16).frame(width: columnWidth, alignment: .leading)
                        .background(WhiskyStyle.surface).cornerRadius(12)
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func actions(_ game: WorkspaceGame) -> some View {
        let phase = runtime.launch.state(for: game.item)
        if phase.isPending {
            WhiskyAction("取消启动") { cancel(game) }.disabled(!capabilities(game.item).contains(.cancelLaunch))
        } else if phase == .running {
            WhiskyAction("停止游戏") { stop(game) }.disabled(!capabilities(game.item).contains(.stop))
        } else {
            WhiskyAction(game.lastSessionEndedAt == nil ? "▶ 游玩" : "▶ 继续游玩", prominent: true) { launch(game) }
                .disabled(!capabilities(game.item).contains(.launch))
        }
    }

    private func status(_ game: WorkspaceGame) -> String {
        switch runtime.launch.state(for: game.item) {
        case .idle: capabilities(game.item).contains(.launch) ? "就绪" : "浏览模式"
        case .preparing: "准备中"
        case .launching: "启动中"
        case .checkingLaunch: "确认进程中"
        case .startingSteam: "启动 Steam"
        case .waitingForSteam: "等待 Steam"
        case .running: "运行中"
        }
    }
}

func playTime(_ seconds: TimeInterval) -> String {
    let bounded = seconds.isFinite ? min(max(0, seconds), 315_576_000_000) : 0
    return Duration.seconds(bounded).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
}

struct WorkspaceGameDetail: View {
    let game: WorkspaceGame
    let artwork: any ArtworkProviding
    let dismiss: @MainActor @Sendable () -> Void
    let launch: @MainActor @Sendable () -> Void
    var canLaunch = false
    var changed: @MainActor () async -> Void = {}
    @State private var rating = ""
    @State private var hidden = false
    @State private var message = ""
    private let edits = WorkspaceEdits()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("游戏详情").font(.system(size: 18, weight: .semibold))
                Spacer()
                WhiskyAction("完成", action: dismiss)
            }
            HStack(alignment: .top, spacing: 24) {
                CoverArtwork(
                    source: game.artwork,
                    provider: artwork,
                    width: 190,
                    height: 285,
                    cacheDirectory: game.item.metadataDirectory
                ).cornerRadius(9)
                VStack(alignment: .leading, spacing: 14) {
                    Text(game.title).font(.system(size: 26, weight: .bold)).lineLimit(3)
                    if let metadata = game.presentation.metadata {
                        Text(metadata.originalTitle).foregroundColor(WhiskyStyle.secondary).lineLimit(2)
                        Text("开发商：\(metadata.developer)")
                        Text("发售日期：\(metadata.releaseDate)")
                        Text("资料来源：\(metadata.source.title)")
                    }
                    Text("容器：\(game.containerName)")
                    Text("累计游玩：\(playTime(game.presentation.activity.playTime))")
                    if let rating = game.presentation.activity.rating {
                        Text("我的评分：★ \(rating)/10")
                    }
                    if let date = game.lastSessionEndedAt {
                        Text("上次游玩结束：\(date.formatted())")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            ScrollView {
                Text(game.presentation.metadata?.summary ?? "游戏资料为空")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 180)
            HStack {
                Text("我的评分")
                TextField("0–10", text: $rating).frame(width: 65)
                WhiskyAction("保存评分") { Task { await saveRating() } }
                WhiskyAction(hidden ? "显示游戏" : "隐藏游戏") { Task { await changeVisibility() } }
                Spacer()
                WhiskyAction("显示文件") {
                    do {
                        if case let .program(url) = game.item.launch {
                            try WorkspaceSystem.show(url)
                        }
                    } catch { message = error.localizedDescription }
                }
                WhiskyAction("▶ 游玩", prominent: true, action: launch).disabled(!canLaunch)
            }
            if !message.isEmpty {
                Text(message).font(.system(size: 11)).foregroundColor(WhiskyStyle.secondary)
            }
        }
        .padding(26).frame(width: 740).background(WhiskyStyle.background)
        .onAppear { rating = game.presentation.activity.rating.map(String.init) ?? ""
            hidden = game.hidden
        }
    }

    private func saveRating() async {
        let text = rating.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = Int(text)
        guard text.isEmpty || value != nil else { message = "请输入 0–10 的整数"
            return
        }
        do {
            try await edits.setRating(value, for: game.item)
            message = "评分已保存"
            await changed()
        } catch { message = error.localizedDescription }
    }

    private func changeVisibility() async {
        do {
            try await edits.setHidden(!hidden, for: game.item)
            hidden.toggle()
            message = hidden ? "游戏已隐藏" : "游戏已显示"
            await changed()
        } catch { message = error.localizedDescription }
    }
}
