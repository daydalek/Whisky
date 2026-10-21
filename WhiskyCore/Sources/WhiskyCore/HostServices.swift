//
//  HostServices.swift
//  WhiskyCore
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

@MainActor
public protocol DirectoryPicking {
    func chooseDirectory(initialDirectory: URL?) async -> URL?
}

@MainActor
public protocol TerminalLaunching {
    func openScript(at url: URL) async throws
}

@MainActor
public protocol ProgramUserInteraction {
    var launchMode: LibraryLaunchRequest.Mode { get }
    func showLaunchFailure(programName: String, message: String)
    func decideClipboard(_ snapshot: ClipboardSnapshot) -> ClipboardDecision
}

public struct TerminalLaunchError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

public enum TerminalScriptWriter {
    /// POSIX hosts hand a prepared command to their chosen terminal as an executable script.
    public static func write(
        command: String, directory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        guard directory.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
        let url = directory.appendingPathComponent("whisky-run-\(UUID().uuidString).sh")
        do {
            try "#!/bin/bash\n\(command)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
