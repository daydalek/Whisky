//
//  ContainerJournal.swift
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

/// Persisted before the first tree mutation. The registry commit ID is the
/// single authoritative boundary between rollback and completing cleanup.
struct ContainerJournal: Codable, Sendable {
    enum Kind: String, Codable { case duplicate, move, crossMove, remove }
    let version: Int
    let id: UUID
    let kind: Kind
    let source: URL
    let destination: URL
    let sourceIdentity: DirectoryIdentity
    let destinationIdentity: DirectoryIdentity?
    let originalPaths: [URL]
    let undo: ContainerUndo?
    let routeSources: [String]?

    init(
        kind: Kind, source: URL, destination: URL,
        paths: [URL], undo: ContainerUndo? = nil, registry: URL? = nil
    ) throws {
        version = 1
        id = UUID()
        self.kind = kind
        self.source = source
        self.destination = destination
        sourceIdentity = try DirectoryIdentity.require(source)
        destinationIdentity = kind == .duplicate || kind == .crossMove ? try DirectoryIdentity
            .require(destination) : nil
        originalPaths = paths
        self.undo = undo
        routeSources = try kind == .duplicate ? nil : registry.map {
            try ContainerRoutes.sources(source: source, paths: paths, registry: $0)
        }
    }

    static func location(_ registry: URL) -> URL {
        registry.appendingPathExtension("lifecycle.plist")
    }

    static func present(_ url: URL) -> Bool {
        var device: UInt64 = 0, inode: UInt64 = 0
        var kind: Int32 = 0
        let error = whisky_host_identity(url.path, &device, &inode, &kind)
        return error != ENOENT && error != ENOTDIR
    }

    static func pending(_ registry: URL) -> Bool {
        present(location(registry)) || present(ExportJournal.location(registry))
    }

    static func requireClear(_ registry: URL) throws {
        guard !pending(registry) else {
            throw BridgeFailure(
                "recovery_pending",
                "Recover the interrupted container operation first",
                retryable: true
            )
        }
    }

    func save(_ registry: URL) throws {
        try Self.requireClear(registry)
        let data = try PropertyListEncoder().encode(self)
        guard data.count <= 64 * 1_024 * 1_024 else {
            throw BridgeFailure("journal_too_large", "The container undo plan exceeds 64 MiB")
        }
        try Self.publish(data, at: Self.location(registry), replace: false)
    }

    static func publish(_ data: Data, at url: URL, replace: Bool) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".whisky-journal-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor)
            try? FileManager.default.removeItem(at: temporary)
        }
        try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: data)
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let result = replace ? rename(temporary.path, url.path) : link(temporary.path, url.path)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    static func read(_ registry: URL) throws -> Self {
        let url = location(registry)
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              (attributes.fileSize ?? .max) <= 64 * 1_024 * 1_024
        else {
            throw BridgeFailure("recovery_required", "The lifecycle journal requires inspection: \(url.path)")
        }
        let journal = try PropertyListDecoder().decode(Self.self, from: Data(contentsOf: url))
        try journal.validate(registry)
        return journal
    }

    func validate(_ registry: URL) throws {
        guard version == 1, source.isFileURL, destination.isFileURL,
              source.path.hasPrefix("/"), destination.path.hasPrefix("/"), source.path != "/",
              source.path != destination.path, !registry.path.hasPrefix(source.path + "/"),
              !destination.path.hasPrefix(source.path + "/"), !source.path.hasPrefix(destination.path + "/"),
              !originalPaths.isEmpty, originalPaths.allSatisfy(\.isFileURL)
        else {
            throw BridgeFailure("recovery_required", "The lifecycle journal has invalid locations")
        }
        guard destination.path != "/", !registry.path.hasPrefix(destination.path + "/") else {
            throw BridgeFailure("recovery_required", "The recovery destination crosses the registry boundary")
        }
        if kind == .duplicate {
            guard destination.deletingLastPathComponent().path == source.deletingLastPathComponent().path,
                  UUID(uuidString: destination.lastPathComponent) != nil, destinationIdentity != nil
            else {
                throw BridgeFailure("recovery_required", "Invalid clone recovery location")
            }
        }
        if kind == .move || kind == .crossMove {
            guard destination.lastPathComponent == source.lastPathComponent else {
                throw BridgeFailure("recovery_required", "Invalid move recovery location")
            }
        }
        guard kind != .move || undo != nil else {
            throw BridgeFailure("recovery_required", "The move journal requires an undo plan")
        }
        if kind == .remove {
            guard destination.deletingLastPathComponent().path == source.deletingLastPathComponent().path,
                  destination.lastPathComponent.hasPrefix(".whisky-removing-"),
                  UUID(uuidString: String(destination.lastPathComponent.dropFirst(".whisky-removing-".count))) != nil
            else { throw BridgeFailure("recovery_required", "Invalid removal staging location") }
        }
    }

    static func clear(_ registry: URL) throws {
        if present(location(registry)) {
            try FileManager.default.removeItem(at: location(registry))
        }
    }
}

struct DirectoryIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64

    static func read(_ url: URL) throws -> Self? {
        var device: UInt64 = 0, inode: UInt64 = 0
        var directory: Int32 = 0
        let error = whisky_host_identity(url.path, &device, &inode, &directory)
        if error == ENOENT || error == ENOTDIR {
            return nil
        }
        guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
        guard directory == 1
        else { throw BridgeFailure("recovery_required", "Expected an owned directory: \(url.path)") }
        return Self(device: device, inode: inode)
    }

    static func require(_ url: URL) throws -> Self {
        guard let identity = try read(url) else {
            throw BridgeFailure("recovery_required", "Directory is unavailable: \(url.path)")
        }
        return identity
    }
}
