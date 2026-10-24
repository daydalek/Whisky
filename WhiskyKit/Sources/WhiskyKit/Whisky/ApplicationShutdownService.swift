//
//  ApplicationShutdownService.swift
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

/// The same explicit quit policy is available to every frontend composition.
@MainActor
public enum ApplicationShutdownService {
    public static func apply(
        to bottles: [Bottle], globalKill: Bool,
        terminate: (Bottle) -> Void = { Wine.killBottleAndWait(bottle: $0) },
        clearProcesses: (URL) -> Void = { ProcessRegistry.shared.clearRegistry(for: $0) },
        temporaryFiles: [URL]? = nil
    ) {
        SettingsPersistence.shared.flush()
        for bottle in bottles {
            let shouldKill: Bool = switch bottle.settings.killOnQuit {
            case .inherit: globalKill
            case .alwaysKill: true
            case .neverKill: false
            }
            if shouldKill {
                terminate(bottle)
                clearProcesses(bottle.url)
            }
        }
        let files = temporaryFiles ?? TempFileTracker.shared.getAllTrackedFiles().map(\.0)
        for url in files {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
