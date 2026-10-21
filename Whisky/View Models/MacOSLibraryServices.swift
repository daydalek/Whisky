//
//  MacOSLibraryServices.swift
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
import UniformTypeIdentifiers
import WhiskyCore
import WhiskyKit

@MainActor
struct MacOSExecutablePicker: ExecutablePicker {
    func chooseExecutable(in directory: URL) async -> URL? {
        let panel = NSOpenPanel()
        panel.directoryURL = directory
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .data]
        return await panel.begin() == .OK ? panel.url : nil
    }
}

@MainActor
private enum MacOSLibraryRuntime {
    static let shared: any LibraryRuntime = {
        let driver = WineLibraryRuntimeDriver(
            bottleResolver: { url in BottleVM.shared.bottles.first { $0.url == url } },
            driverFactory: { AppSteamClientDriver(bottle: $0) }
        )
        return LibraryRuntimeController(driver: driver)
    }()
}

extension LibraryModel {
    convenience init() {
        self.init(
            runtime: MacOSLibraryRuntime.shared,
            content: WineLibraryContentService(bottleResolver: { url in
                BottleVM.shared.bottles.first { $0.url == url }
            }),
            executablePicker: MacOSExecutablePicker()
        ) {
            NSEvent.modifierFlags.contains(.shift)
        }
    }
}
