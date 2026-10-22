//
//  ContainerRegistry.swift
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

/// A registry lease serializes lifecycle operations across independent helpers.
/// Taking a busy lease fails promptly so a bridge request can keep its deadline.
enum ContainerRegistry {
    static func acquire(_ workspace: ApplicationWorkspace) throws -> Int32 {
        guard workspace.explicitContainers.isEmpty else {
            throw BridgeFailure("read_only_workspace", "Lifecycle changes require a persisted registry")
        }
        return try lock(workspace, exclusive: true)
    }

    static func acquireShared(_ workspace: ApplicationWorkspace) throws -> Int32? {
        guard workspace.explicitContainers.isEmpty,
              FileManager.default.fileExists(atPath: workspace.registry.path)
        else { return nil }
        return try lock(workspace, exclusive: false)
    }

    private static func lock(_ workspace: ApplicationWorkspace, exclusive: Bool) throws -> Int32 {
        let url = workspace.registry.appendingPathExtension("lock")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            close(descriptor)
            throw BridgeFailure("busy", "Another container operation holds this registry", retryable: true)
        }
        return descriptor
    }

    static func release(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    private struct Paths: Codable { var paths: [URL] }

    struct Document {
        let url: URL
        private var values: [String: Any]
        private let format: PropertyListSerialization.PropertyListFormat
        var paths: [URL]

        init(_ workspace: ApplicationWorkspace) throws {
            url = workspace.registry
            var format = PropertyListSerialization.PropertyListFormat.binary
            let data = try ApplicationWorkspace.read(url)
            guard let values = try PropertyListSerialization.propertyList(from: data, format: &format)
                as? [String: Any]
            else { throw CocoaError(.fileReadCorruptFile) }
            paths = try PropertyListDecoder().decode(Paths.self, from: data).paths
            guard paths.allSatisfy(\.isFileURL) else { throw CocoaError(.fileReadCorruptFile) }
            self.values = values
            self.format = format
        }

        func resolve(_ params: [String: JSONValue]) throws -> URL {
            let target = try canonical(params.path("container"))
            guard paths.contains(where: { canonical($0) == target }) else {
                throw BridgeFailure("unknown_container", "Container is outside this workspace")
            }
            return target
        }

        var committedTransaction: String? {
            values["whiskyLifecycleCommit"] as? String
        }

        mutating func save(_ paths: [URL], transaction: UUID? = nil) throws {
            let encoded = try PropertyListEncoder().encode(Paths(paths: paths))
            let updated = try PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any]
            values["paths"] = updated?["paths"]
            if let transaction {
                values["whiskyLifecycleCommit"] = transaction.uuidString
            }
            try PropertyListSerialization.data(fromPropertyList: values, format: format, options: 0)
                .write(to: url, options: .atomic)
            self.paths = paths
        }
    }

    static func canonical(_ url: URL) -> URL {
        URL(fileURLWithPath: url.resolvingSymlinksInPath().standardizedFileURL.path, isDirectory: true)
    }
}
