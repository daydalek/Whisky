//
//  MacOSApplicationServices+Programs+Run.swift
//  WhiskyNativeBridge
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
import WhiskyBridgeProtocol
import WhiskyKit

extension MacOSApplicationServices {
    /// Runs a file picked by the user (Open With, drag and drop, or the Run
    /// panel). The operation outlives the call, so it is a job: callers poll
    /// `jobs.get` for failures during startup instead of blocking on the game.
    func runProgram(_ params: [String: JSONValue], workspace: ApplicationWorkspace) throws -> JSONValue {
        let container = try workspace.resolve(params)
        guard let bottle = bottle(container) else {
            throw BridgeFailure("invalid_container", "Wine settings are unreadable")
        }
        let executable = try params.path("executable")
        let runnable = ["exe", "msi", "bat", "msix", "appx", "url"]
        guard runnable.contains(executable.pathExtension.lowercased()) else {
            throw BridgeFailure("invalid_params", "Expected a runnable Windows file")
        }
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw BridgeFailure("file_missing", "Selected file is unavailable")
        }
        let program = bottle.programs.first { $0.url == executable }
        let choice = program?.settings.overrides?.graphicsBackend ?? bottle.settings.graphicsBackend
        let resolved = if choice == .recommended {
            GraphicsBackendResolver.resolve(for: LauncherType.detect(from: executable))
        } else {
            choice
        }
        let backend = resolved.displayName
        return try jobs.start(name: "programs.run", extra: ["backend": .string(backend)]) { _ in
            if executable.pathExtension.lowercased() == "bat" {
                _ = try await Wine.runBatchFile(url: executable, bottle: bottle)
            } else {
                _ = try await Program(url: executable, bottle: bottle, peFile: nil).launch()
            }
            return .object(["path": .string(executable.path)])
        }
    }
}
