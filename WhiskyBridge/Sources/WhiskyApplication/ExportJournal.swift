//
//  ExportJournal.swift
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
import WhiskyCore
#if os(Linux)
import Glibc
#elseif os(macOS)
import Darwin
#endif

struct ExportJournal: Codable, Sendable {
    let id: UUID
    let source: URL
    let destination: URL
    let temporary: URL
    let identity: RegularFileIdentity
    struct Process: Codable, Sendable {
        let pid: Int32
        let birth: UInt64
        var identity: HostProcessIdentity {
            HostProcessIdentity(pid: pid, birth: birth)
        }
    }

    var child: Process?
    var prepared = false

    init(source: URL, destination: URL, temporary: URL) throws {
        id = UUID()
        self.source = source
        self.destination = destination
        self.temporary = temporary
        identity = try RegularFileIdentity.require(temporary)
    }

    static func location(_ registry: URL) -> URL {
        registry.appendingPathExtension("export.plist")
    }

    func save(_ registry: URL, replace: Bool = false) throws {
        if !replace {
            try ContainerJournal.requireClear(registry)
        }
        try ContainerJournal.publish(PropertyListEncoder().encode(self), at: Self.location(registry), replace: replace)
    }

    static func read(_ registry: URL) throws -> Self {
        let url = location(registry)
        _ = try RegularFileIdentity.require(url)
        let data = try ApplicationWorkspace.read(url)
        let value = try PropertyListDecoder().decode(Self.self, from: data)
        guard value.source.isFileURL, value.destination.isFileURL, value.temporary.isFileURL,
              value.source.path != "/", value.destination.pathExtension.lowercased() == "tar",
              value.temporary.deletingLastPathComponent().path == value.destination.deletingLastPathComponent().path,
              value.temporary.lastPathComponent.hasPrefix(".whisky-export-"),
              UUID(uuidString: String(value.temporary.lastPathComponent.dropFirst(".whisky-export-".count))) != nil,
              !value.temporary.path.hasPrefix(value.source.path + "/"), value.destination != value.temporary
        else {
            throw BridgeFailure("recovery_required", "Export journal requires inspection: \(url.path)")
        }
        return value
    }

    static func recover(_ registry: URL) throws -> JSONValue {
        let record = try read(registry)
        if let child = record.child, HostProcessIdentityProvider().isAlive(child.identity), !zombie(child.pid) {
            throw BridgeFailure("busy", "Waiting for the owned exporter to exit", retryable: true)
        }
        let destination = record.prepared ? try RegularFileIdentity.read(record.destination, allowOther: true) : nil
        let published = record.prepared && destination == record.identity
        if let temporary = try RegularFileIdentity.read(record.temporary) {
            guard temporary == record.identity else {
                throw BridgeFailure("recovery_required", "Export temporary file was replaced: \(record.temporary.path)")
            }
            try FileManager.default.removeItem(at: record.temporary)
        }
        try FileManager.default.removeItem(at: location(registry))
        return .object([
            "recovered": .bool(true),
            "transactionID": .string(record.id.uuidString),
            "outcome": .string(published ? "published" : "rolled_back")
        ])
    }

    private static func zombie(_ pid: Int32) -> Bool {
        #if os(Linux)
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let end = stat.lastIndex(of: ")")
        else { return false }
        return stat[stat.index(after: end)...].split(separator: " ").first.map { $0 == "Z" || $0 == "X" } ?? false
        #else
        return false
        #endif
    }
}

struct RegularFileIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64

    static func read(_ url: URL, allowOther: Bool = false) throws -> Self? {
        var device: UInt64 = 0, inode: UInt64 = 0
        var kind: Int32 = 0
        let error = whisky_host_identity(url.path, &device, &inode, &kind)
        if error == ENOENT || error == ENOTDIR {
            return nil
        }
        guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
        if kind != 2, allowOther {
            return nil
        }
        guard kind == 2 else {
            throw BridgeFailure("recovery_required", "Expected an owned regular file: \(url.path)")
        }
        return Self(device: device, inode: inode)
    }

    static func require(_ url: URL) throws -> Self {
        guard let identity = try read(url) else { throw CocoaError(.fileReadNoSuchFile) }
        return identity
    }
}
