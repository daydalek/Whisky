//
//  ContainerLifecycleService+Export.swift
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
    static func export(
        _ params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) async throws -> JSONValue {
        let lease = try ContainerRegistry.acquire(workspace)
        defer { ContainerRegistry.release(lease) }
        try ContainerJournal.requireClear(workspace.registry)
        let initial = try prepareExport(params, workspace: workspace)
        do { return try await runExport(initial, registry: workspace.registry) } catch {
            do { _ = try ExportJournal.recover(workspace.registry) } catch let recovery {
                throw BridgeFailure(
                    "recovery_required",
                    "Export recovery retained its journal: \(recovery.localizedDescription)"
                )
            }
            throw error
        }
    }

    private static func prepareExport(
        _ params: [String: JSONValue], workspace: ApplicationWorkspace
    ) throws -> ExportJournal {
        let registry = try ContainerRegistry.Document(workspace)
        let source = try registry.resolve(params)
        try validate(source, registry: workspace.registry)
        let requested = try params.path("destination").standardizedFileURL
        let parent = ContainerRegistry.canonical(requested.deletingLastPathComponent())
        let destination = parent.appendingPathComponent(requested.lastPathComponent)
        guard destination.pathExtension.lowercased() == "tar", parent != source,
              !parent.path.hasPrefix(source.path + "/"), !exists(destination)
        else {
            throw BridgeFailure("invalid_params", "Expected a new .tar destination outside the container")
        }
        let staging = parent.appendingPathComponent(".whisky-export-" + UUID().uuidString)
        let descriptor = open(staging.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(descriptor)
        let initial: ExportJournal
        do {
            initial = try ExportJournal(source: source, destination: destination, temporary: staging)
            try initial.save(workspace.registry)
        } catch {
            if !ContainerJournal.present(ExportJournal.location(workspace.registry)) {
                try? FileManager.default.removeItem(at: staging)
            }
            throw error
        }
        return initial
    }

    private static func runExport(_ initial: ExportJournal, registry: URL) async throws -> JSONValue {
        let source = initial.source
        let staging = initial.temporary
        let destination = initial.destination
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
            environment: environment, timeout: 3_600, onSpawn: { pid in
                let birth = HostProcessIdentityProvider.processBirth(for: pid)
                guard birth > 0 else { throw BridgeFailure("host_failed", "Could not identify the owned exporter") }
                var running = initial
                running.child = .init(pid: pid, birth: birth)
                try running.save(registry, replace: true)
            }
        )
        guard result.status == 0, !result.signalled else { throw BridgeFailure(
            "archive_failed",
            "Container export failed"
        ) }
        try Task.checkCancellation()
        guard try RegularFileIdentity.require(staging) == initial.identity else {
            throw BridgeFailure("recovery_required", "Export temporary file was replaced")
        }
        var prepared = try ExportJournal.read(registry)
        prepared.prepared = true
        try prepared.save(registry, replace: true)
        guard link(staging.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        _ = try ExportJournal.recover(registry)
        return .object(["path": .string(destination.path)])
    }
}
