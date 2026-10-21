//
//  WorkspaceSystem.swift
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
#if os(macOS)
import AppKit
#endif

@MainActor
enum WorkspaceSystem {
    static func show(_ url: URL) throws {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #elseif os(Linux)
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        try open(isDirectory ? url : url.deletingLastPathComponent())
        #endif
    }

    static func open(_ url: URL) throws {
        #if os(macOS)
        guard NSWorkspace.shared.open(url) else { throw CocoaError(.fileReadUnsupportedScheme) }
        #elseif os(Linux)
        guard let opener = locateXDGOpen() else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "xdg-open is unavailable on this host"])
        }
        let process = Process()
        process.executableURL = opener
        process.arguments = [url.path]
        process.terminationHandler = { _ in }
        try process.run()
        #endif
    }

    #if os(Linux)
    /// Mirrors the PATH lookup used by the bridge host's `xdgOpen` helper.
    private static func locateXDGOpen() -> URL? {
        var directories = ["/usr/bin", "/usr/local/bin", "/bin"].map { URL(fileURLWithPath: $0) }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            directories += path.split(separator: ":").filter { $0.hasPrefix("/") }
                .map { URL(fileURLWithPath: String($0)) }
        }
        for directory in directories {
            let candidate = directory.appendingPathComponent("xdg-open")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
    #endif
}
