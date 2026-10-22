//
//  ContainerImportService.swift
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

/// Reads imported metadata directly and registers existing prefixes in place.
/// A registry-only atomic write leaves every source byte and symlink intact.
enum ContainerImportService {
    struct Candidate: Codable {
        let path: String
        let name: String
        let device: String
        let inode: String
    }

    static func candidate(_ url: URL, workspace: ApplicationWorkspace) throws -> Candidate {
        let url = ContainerRegistry.canonical(url)
        try ContainerLifecycleService.validate(url, registry: workspace.registry)
        let identity = try DirectoryIdentity.require(url)
        let values = try PropertyListSerialization.propertyList(
            from: ApplicationWorkspace.read(url.appendingPathComponent("Metadata.plist")), format: nil
        ) as? [String: Any]
        guard let info = values?["info"] as? [String: Any], let name = info["name"] as? String else {
            throw BridgeFailure("invalid_container", "Container metadata is unreadable")
        }
        return Candidate(path: url.path, name: name, device: String(identity.device), inode: String(identity.inode))
    }

    static func discover(roots: [URL], workspace: ApplicationWorkspace) throws -> JSONValue {
        try ContainerJournal.requireClear(workspace.registry)
        let existing = try Set(workspace.containers().map { ContainerRegistry.canonical($0).path })
        var seen = existing
        var candidates: [Candidate] = []
        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            guard children.count <= 50_000 else { throw BridgeFailure(
                "too_many_entries",
                "Discovery root exceeds 50000 entries"
            ) }
            for child in children where !child.lastPathComponent.hasPrefix(".") {
                let canonical = ContainerRegistry.canonical(child)
                guard seen.insert(canonical.path).inserted else { continue }
                if let value = try? candidate(canonical, workspace: workspace) {
                    candidates.append(value)
                }
            }
        }
        return try .encoded(candidates.sorted { $0.path < $1.path })
    }

    static func register(_ params: [String: JSONValue], workspace: ApplicationWorkspace) throws -> JSONValue {
        let lease = try ContainerRegistry.acquire(workspace)
        defer { ContainerRegistry.release(lease) }
        try ContainerJournal.requireClear(workspace.registry)
        let paths: [URL]
        if let values = params["paths"] {
            guard case let .array(array) = values, !array.isEmpty, array.count <= 128 else {
                throw BridgeFailure("invalid_params", "Expected 1 to 128 container paths")
            }
            paths = try array.map { try ["path": $0].path("path") }
        } else {
            paths = try [params.path("path")]
        }
        let candidates = try paths.map { try candidate($0, workspace: workspace) }
        if params["device"] != nil || params["inode"] != nil {
            guard candidates.count == 1, params["device"]?.string == candidates[0].device,
                  params["inode"]?.string == candidates[0].inode
            else {
                throw BridgeFailure("candidate_changed", "The discovered directory changed; scan again")
            }
        }
        var registry = try ContainerRegistry.Document(workspace, allowMissing: true)
        var known = Set(registry.paths.map { ContainerRegistry.canonical($0).path })
        let additions = candidates.filter { known.insert($0.path).inserted }
        if !additions.isEmpty {
            try registry.save(registry.paths + additions.map { URL(fileURLWithPath: $0.path, isDirectory: true) })
        }
        return try .object(["containers": .encoded(candidates), "imported": .integer(Int64(additions.count))])
    }
}
