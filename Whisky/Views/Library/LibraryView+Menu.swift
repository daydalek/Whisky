//
//  LibraryView+Menu.swift
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

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WhiskyKit

extension LibraryView {
    @ViewBuilder
    func menu(for row: LibraryRow) -> some View {
        menuLaunchActions(for: row)
        Divider()
        menuVisibilityActions(for: row)
        menuProgramActions(for: row)
        Button("library.card.configure") {
            selectedBottle = row.item.bottleURL
        }
    }

    @ViewBuilder
    private func menuLaunchActions(for row: LibraryRow) -> some View {
        Button("button.run") { model.launch(row, bottles: bottles) }
            .disabled(model.state(for: row.item).isPending)
        if case .steam = row.item.launch, model.state(for: row.item).isPending {
            Button("library.steam.cancelWaiting") { model.cancelLaunch(row) }
        }
        if case .steam = row.item.launch, model.state(for: row.item) == .running {
            Button("library.card.stop") { model.stop(row, bottles: bottles) }
        }
    }

    @ViewBuilder
    private func menuVisibilityActions(for row: LibraryRow) -> some View {
        Button {
            model.setHidden(!model.isHidden(row.item), for: row.item)
        } label: {
            Label(
                model.isHidden(row.item) ? "library.visibility.unhide" : "library.visibility.hide",
                systemImage: model.isHidden(row.item) ? "eye" : "eye.slash"
            )
        }
        if !row.item.isLauncher {
            Button("library.metadata.details") { detailRow = row }
        }
        if let directory = row.item.gameDirectoryURL {
            Button("library.game.openDirectory") {
                NSWorkspace.shared.open(directory)
            }
        }
    }

    @ViewBuilder
    private func menuProgramActions(for row: LibraryRow) -> some View {
        if case let .program(url) = row.item.launch {
            if bottles.count > 1 {
                Menu("library.bottle.target") {
                    Picker("library.bottle.target", selection: Binding(
                        get: { row.item.bottleURL },
                        set: { targetURL in
                            guard let target = bottles.first(where: { $0.url == targetURL }) else { return }
                            Task { await model.moveEntry(row.item, to: target, bottles: bottles) }
                        }
                    )) {
                        ForEach(bottles, id: \.url) { bottle in
                            Text(bottle.settings.name).tag(bottle.url)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            if row.item.source == .folder {
                Button("library.scan.executable") {
                    Task { _ = await model.folderExecutable(row.item, chooseAgain: true) }
                }
            }
            Button("library.program.settings") {
                Task {
                    guard let bottle = bottles.first(where: { $0.url == row.item.bottleURL }),
                          let executable = row.item.source == .folder
                          ? await model.folderExecutable(row.item)
                          : url
                    else { return }
                    settingsProgram = bottle.programs.first(where: { $0.url == executable })
                        ?? Program(url: executable, bottle: bottle)
                }
            }
            Button("button.showInFinder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            if row.item.source != .folder {
                Button("library.card.unpin", role: .destructive) {
                    unpin(url, in: row.item.bottleURL)
                }
            }
        } else if case .steam = row.item.launch {
            Button("library.program.settings") { steamSettingsRow = row }
        }
    }
}
