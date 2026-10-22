//
//  LinuxDesktopEntry.swift
//  WhiskyApplication
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
import WhiskyBridgeProtocol
#if os(Linux)
import Glibc
#elseif os(macOS)
import Darwin
#endif

/// Desktop-file quoting has a value-escape layer followed by Exec argument quoting.
enum LinuxDesktopEntry {
    static func value(_ text: String) -> String {
        text.map { character in
            switch character {
            case "\\": "\\\\"
            case "\n": "\\n"
            case "\r": "\\r"
            case "\t": "\\t"
            default: String(character)
            }
        }.joined()
    }

    static func argument(_ text: String) -> String {
        let quoted = text.map { character -> String in
            switch character {
            case "\\", "\"", "$", "`": "\\" + String(character)
            case "%": "%%"
            default: String(character)
            }
        }.joined()
        return value("\"" + quoted + "\"")
    }

    static func contents(name: String, launcher: URL, arguments: [String], handlesFiles: Bool) -> String {
        // A fixed POSIX launcher also supports executable paths containing '='.
        let command = ["/bin/sh", "-c", "exec \"$@\"", "whisky-desktop", launcher.path] + arguments
        let exec = command.map(argument).joined(separator: " ") + (handlesFiles ? " %f" : "")
        let types = [
            "application/x-ms-dos-executable",
            "application/x-msdownload",
            "application/x-msi",
            "application/vnd.microsoft.portable-executable"
        ].joined(separator: ";")
        return """
        [Desktop Entry]
        Version=1.0
        Type=Application
        Name=\(value(name))
        Exec=\(exec)
        Icon=applications-games
        Terminal=false
        StartupNotify=false
        Categories=Game;
        X-Whisky-Managed=true
        X-Whisky-Launcher=\(value(launcher.path))
        \(handlesFiles ? "MimeType=\(types);" : "")
        """ + "\n"
    }

    /// Creates or acknowledges the exact existing bytes; foreign targets retain their contents.
    static func publish(_ contents: String, at target: URL) throws {
        let bytes = Data(contents.utf8)
        let staging = target.deletingLastPathComponent().appendingPathComponent(".whisky-desktop-" + UUID().uuidString)
        let descriptor = open(staging.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, mode_t(0o755))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor)
            _ = unlink(staging.path)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
        guard link(staging.path, target.path) == 0 else {
            if errno == EEXIST, regularContents(target) == bytes {
                return
            }
            if errno == EEXIST {
                throw BridgeFailure("destination_exists", "A different desktop entry already exists")
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func regularContents(_ url: URL) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return nil }
        let data = try? FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).read(upToCount: 65_537)
        return data.flatMap { $0.count <= 65_536 ? $0 : nil }
    }
}
