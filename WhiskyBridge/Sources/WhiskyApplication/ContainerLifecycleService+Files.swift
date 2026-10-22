//
//  ContainerLifecycleService+Files.swift
//  WhiskyBridge
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

extension ContainerLifecycleService {
    nonisolated static func copyContents(
        _ source: URL, to destination: URL, cleanTransient: Bool = true, relative: String = ""
    ) throws {
        // FileManager preserves file modes and copies symlinks as symlinks.
        // Walking directories explicitly provides cancellation between files.
        for url in try FileManager.default.contentsOfDirectory(
            at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) {
            try Task.checkCancellation()
            if cleanTransient, url.lastPathComponent.hasSuffix(".diagnosis-history.plist") {
                continue
            }
            if cleanTransient, relative == "logs", url.pathExtension == "log" {
                continue
            }
            let target = destination.appendingPathComponent(url.lastPathComponent)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory == true, values.isSymbolicLink != true {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                try copyContents(
                    url, to: target, cleanTransient: cleanTransient,
                    relative: relative.isEmpty ? url.lastPathComponent : relative + "/" + url.lastPathComponent
                )
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                try FileManager.default.setAttributes([
                    .posixPermissions: attributes[.posixPermissions] ?? 0o700,
                    .modificationDate: attributes[.modificationDate] ?? Date()
                ], ofItemAtPath: target.path)
            } else {
                try FileManager.default.copyItem(at: url, to: target)
            }
        }
    }

    nonisolated static func removeOwnedCopy(_ directory: URL) throws {
        // The caller verifies ownership of the staged or retired directory.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if let iterator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) {
            for case let url as URL in iterator {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory == true, values.isSymbolicLink != true {
                    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
                }
            }
        }
        try FileManager.default.removeItem(at: directory)
    }

    static func export(
        _ params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) async throws -> JSONValue {
        let lease = try ContainerRegistry.acquire(workspace)
        defer { ContainerRegistry.release(lease) }
        try ContainerJournal.requireClear(workspace.registry)
        let registry = try ContainerRegistry.Document(workspace)
        let source = try registry.resolve(params)
        try validate(source, registry: workspace.registry)
        let destination = try params.path("destination").standardizedFileURL
        let parent = ContainerRegistry.canonical(destination.deletingLastPathComponent())
        guard destination.pathExtension.lowercased() == "tar", parent != source,
              !parent.path.hasPrefix(source.path + "/"), !exists(destination)
        else {
            throw BridgeFailure("invalid_params", "Expected a new .tar destination outside the container")
        }
        let staging = parent.appendingPathComponent(".whisky-export-" + UUID().uuidString)
        let descriptor = open(staging.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(descriptor)
        defer { try? FileManager.default.removeItem(at: staging) }
        var environment = ProcessInfo.processInfo.environment
        environment["COPYFILE_DISABLE"] = "1"
        // TAR_OPTIONS can change command semantics; this export owns its options.
        environment["TAR_OPTIONS"] = nil
        let result = try await HostCommand.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: [
                "-zcf",
                staging.path,
                "-C",
                source.deletingLastPathComponent().path,
                "--",
                source.lastPathComponent
            ],
            environment: environment, timeout: 3_600
        )
        guard result.status == 0, !result.signalled else { throw BridgeFailure(
            "archive_failed",
            "Container export failed"
        ) }
        try Task.checkCancellation()
        guard link(staging.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return .object(["path": .string(destination.path)])
    }
}
