//
//  WhiskyCrossUIApp.swift
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

#if os(macOS)
import AppKitBackend
#elseif os(Linux)
import GtkBackend
#elseif os(Windows)
import WinUIBackend
#endif
import DefaultBackend
import SwiftCrossUI
import WhiskyCore

@main
struct WhiskyCrossUIApp: App {
    private let runtime = makeWorkspaceRuntime()
    private let artwork = makeArtworkProvider()
    private let directoryPicker = makeDirectoryPicker()

    var body: some Scene {
        WindowGroup("Whisky · SwiftCrossUI") {
            WorkspaceView(runtime: runtime, artwork: artwork, directoryPicker: directoryPicker)
        }
        .defaultSize(width: 1_200, height: 780)
    }
}
