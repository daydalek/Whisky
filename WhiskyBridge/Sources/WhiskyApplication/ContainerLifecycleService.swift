//
//  ContainerLifecycleService.swift
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

import CHostCommand
import Foundation
import WhiskyBridgeProtocol
#if os(Linux)
import Glibc
#elseif os(macOS)
import Darwin
#endif

/// File-only lifecycle for hosts whose runtime adapter is supplied separately.
@MainActor
final class ContainerLifecycleService {
    static let methods = ["bottle.rename", "bottle.duplicate", "bottle.move", "bottle.remove", "bottle.export"]
    private let jobs: BridgeJobStore
    init(jobs: BridgeJobStore) {
        self.jobs = jobs
    }

    func call(
        _ method: String,
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) async throws -> JSONValue {
        guard Self.methods.contains(method)
        else { throw BridgeFailure("method_unavailable", "Unknown lifecycle method") }
        if method == "bottle.rename" {
            return try await Self.detached { try Self.mutate(method, params: params, workspace: workspace) }
        }
        return try jobs.start(name: method) { progress in
            progress(.object(["stage": .string(method == "bottle.export" ? "archiving" : "updating")]))
            if method == "bottle.export" {
                return try await Self.export(params, workspace: workspace)
            }
            return try await Self.detached { try Self.mutate(method, params: params, workspace: workspace) }
        }
    }

    private nonisolated static func detached(
        _ operation: @escaping @Sendable () throws -> JSONValue
    ) async throws -> JSONValue {
        let task = Task.detached { try operation() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private nonisolated static func mutate(
        _ method: String, params: [String: JSONValue], workspace: ApplicationWorkspace
    ) throws -> JSONValue {
        let lease = try ContainerRegistry.acquire(workspace)
        defer { ContainerRegistry.release(lease) }
        try Task.checkCancellation()
        var registry = try ContainerRegistry.Document(workspace)
        let source = try registry.resolve(params)
        if method == "bottle.remove" {
            return try remove(source, params: params, registry: &registry)
        }
        try validate(source, registry: workspace.registry)
        switch method {
        case "bottle.rename":
            let name = try name(params)
            let url = source.appendingPathComponent("Metadata.plist")
            try HostFileLock().withExclusiveLock(at: url.appendingPathExtension("lock")) {
                var relocation = ContainerRelocation(source: source, destination: source)
                try relocation.apply(at: source, name: name)
            }
            return .object(["container": .string(source.path), "name": .string(name)])
        case "bottle.duplicate":
            return try duplicate(source, name: name(params), registry: &registry)
        case "bottle.move":
            return try move(source, parent: params.path("destination"), registry: &registry)
        default: throw BridgeFailure("method_unavailable", "Unknown lifecycle method")
        }
    }

    nonisolated static func validate(_ source: URL, registry: URL) throws {
        guard source.path != "/", !registry.path.hasPrefix(source.path + "/"),
              try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        else { throw BridgeFailure("invalid_container", "Expected a container directory outside its registry") }
        let marker = source.appendingPathComponent("Metadata.plist")
        let values = try marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw BridgeFailure("invalid_container", "Expected a regular container metadata file")
        }
        guard let document = try PropertyListSerialization.propertyList(
            from: ApplicationWorkspace.read(marker), format: nil
        ) as? [String: Any], let info = document["info"] as? [String: Any], info["name"] is String
        else { throw CocoaError(.fileReadCorruptFile) }
    }

    private nonisolated static func name(_ params: [String: JSONValue]) throws -> String {
        let value = try params.text("name").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\0"), value.utf8.count <= 1_024 else {
            throw BridgeFailure("invalid_params", "Expected a container name of at most 1024 bytes")
        }
        return value
    }

    private nonisolated static func duplicate(
        _ source: URL, name: String, registry: inout ContainerRegistry.Document
    ) throws -> JSONValue {
        let destination = source.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        do {
            try copyContents(source, to: destination)
            var relocation = ContainerRelocation(source: source, destination: destination)
            try relocation.apply(at: destination, name: name)
            try Task.checkCancellation()
            try registry.save(registry.paths + [destination])
        } catch {
            do { try removeOwnedCopy(destination) } catch let cleanup {
                throw BridgeFailure(
                    "recovery_required",
                    "Clone cleanup failed at \(destination.path): \(cleanup.localizedDescription)"
                )
            }
            throw error
        }
        return .object(["path": .string(destination.path), "name": .string(name)])
    }

    private nonisolated static func move(
        _ source: URL, parent: URL, registry: inout ContainerRegistry.Document
    ) throws -> JSONValue {
        let parent = ContainerRegistry.canonical(parent)
        guard try parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
              parent != source, !parent.path.hasPrefix(source.path + "/")
        else {
            throw BridgeFailure("invalid_params", "Expected a destination directory outside the container")
        }
        let destination = parent.appendingPathComponent(source.lastPathComponent)
        guard !exists(destination) else { throw BridgeFailure("destination_exists", "The destination already exists") }
        // Resolve registry aliases while the source still exists.
        let updatedPaths = registry.paths.map { ContainerRegistry.canonical($0) == source ? destination : $0 }
        var relocation = ContainerRelocation(source: source, destination: destination)
        let moveError = whisky_host_move(source.path, destination.path)
        if moveError != 0 {
            guard moveError == EXDEV else { throw POSIXError(POSIXErrorCode(rawValue: moveError) ?? .EIO) }
            return try moveAcrossDevices(source, destination: destination, registry: &registry)
        }
        do {
            try relocation.apply(at: destination)
            try Task.checkCancellation()
            try registry.save(updatedPaths)
        } catch {
            do {
                try relocation.restore(at: destination)
                try FileManager.default.moveItem(at: destination, to: source)
            } catch let rollback {
                throw BridgeFailure(
                    "recovery_required",
                    "Move recovery requires \(destination.path) → \(source.path): \(rollback.localizedDescription)"
                )
            }
            throw error
        }
        return .object(["path": .string(destination.path)])
    }

    private nonisolated static func moveAcrossDevices(
        _ source: URL, destination: URL, registry: inout ContainerRegistry.Document
    ) throws -> JSONValue {
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        do {
            try copyContents(source, to: destination, cleanTransient: false)
            var relocation = ContainerRelocation(source: source, destination: destination)
            try relocation.apply(at: destination)
            try Task.checkCancellation()
            try registry.save(registry.paths.map { ContainerRegistry.canonical($0) == source ? destination : $0 })
        } catch {
            do { try removeOwnedCopy(destination) } catch let cleanup {
                throw BridgeFailure(
                    "recovery_required",
                    "Retained copy at \(destination.path): \(cleanup.localizedDescription)"
                )
            }
            throw error
        }
        do { try FileManager.default.removeItem(at: source) } catch {
            throw BridgeFailure(
                "recovery_required",
                "Container moved to \(destination.path); original files remain at \(source.path)"
            )
        }
        return .object(["path": .string(destination.path)])
    }

    private nonisolated static func remove(
        _ source: URL, params: [String: JSONValue], registry: inout ContainerRegistry.Document
    ) throws -> JSONValue {
        let delete = params["deleteFiles"] == nil ? false : try params.flag("deleteFiles")
        let remaining = registry.paths.filter { ContainerRegistry.canonical($0) != source }
        if !delete {
            try registry.save(remaining)
            return .object(["container": .string(source.path), "deletedFiles": .bool(false)])
        }
        try validate(source, registry: registry.url)
        let staging = source.deletingLastPathComponent().appendingPathComponent(".whisky-removing-" + UUID().uuidString)
        try FileManager.default.moveItem(at: source, to: staging)
        do {
            try Task.checkCancellation()
            try registry.save(remaining)
        } catch {
            do { try FileManager.default.moveItem(at: staging, to: source) } catch let rollback {
                throw BridgeFailure(
                    "recovery_required",
                    "Removal recovery requires \(staging.path): \(rollback.localizedDescription)"
                )
            }
            throw error
        }
        do { try FileManager.default.removeItem(at: staging) } catch {
            throw BridgeFailure(
                "recovery_required",
                "Container deregistered; retained files require cleanup at \(staging.path)"
            )
        }
        return .object(["container": .string(source.path), "deletedFiles": .bool(true)])
    }

    nonisolated static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
}
