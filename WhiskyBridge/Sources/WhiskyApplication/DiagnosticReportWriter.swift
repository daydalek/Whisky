//
//  DiagnosticReportWriter.swift
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

/// Publish a complete report using an exclusive hard link on the destination filesystem.
enum DiagnosticReportWriter {
    static func write(_ report: String, to requested: URL, container: URL, registry: URL) throws {
        let parent = ContainerRegistry.canonical(requested.deletingLastPathComponent())
        let target = parent.appendingPathComponent(requested.lastPathComponent)
        let source = ContainerRegistry.canonical(container)
        guard target.pathExtension.lowercased() == "txt", parent != source, !parent.path.hasPrefix(source.path + "/"),
              ContainerRegistry.canonical(target) != ContainerRegistry.canonical(registry),
              !requested.lastPathComponent.isEmpty
        else {
            throw BridgeFailure("invalid_params", "Choose a .txt report destination outside the container and registry")
        }
        let staging = parent.appendingPathComponent(".whisky-diagnostics-" + UUID().uuidString)
        let descriptor = open(staging.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor)
            _ = unlink(staging.path)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.write(contentsOf: Data(report.utf8))
        try handle.synchronize()
        try Task.checkCancellation()
        guard link(staging.path, target.path) == 0 else {
            if errno == EEXIST {
                throw BridgeFailure("destination_exists", "The report destination already exists")
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
