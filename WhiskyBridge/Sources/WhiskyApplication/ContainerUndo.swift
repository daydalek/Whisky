//
//  ContainerUndo.swift
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

/// A complete undo plan is captured before moving the tree, including links
/// that may be between unlink and recreate when the helper is interrupted.
struct ContainerUndo: Codable, Sendable {
    let files: [String: Data]
    let links: [String: String]

    init(_ source: URL) throws {
        var files: [String: Data] = [:]
        for name in ["Metadata.plist", "Folder Games.json"] {
            let url = source.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw BridgeFailure("invalid_container", "Expected a regular configuration file: \(url.path)")
                }
                files[name] = try ApplicationWorkspace.read(url)
            }
        }
        var links: [String: String] = [:]
        var scanError: (any Error)?
        guard let iterator = FileManager.default.enumerator(
            at: source, includingPropertiesForKeys: [.isSymbolicLinkKey],
            errorHandler: { _, error in scanError = error
                return false
            }
        )
        else { throw CocoaError(.fileReadUnknown) }
        for case let url as URL in iterator {
            try Task.checkCancellation()
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true else { continue }
            iterator.skipDescendants()
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            if target == source.path || target.hasPrefix(source.path + "/") {
                let root = source.resolvingSymlinksInPath().standardizedFileURL.path
                let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
                let path = parent + "/" + url.lastPathComponent
                guard path.hasPrefix(root + "/") else {
                    throw BridgeFailure("invalid_container", "A link moved outside the container during its snapshot")
                }
                links[String(path.dropFirst(root.count + 1))] = target
            }
        }
        if let scanError {
            throw scanError
        }
        self.files = files
        self.links = links
    }

    func restore(at directory: URL) throws {
        for (name, data) in files {
            guard ["Metadata.plist", "Folder Games.json"].contains(name) else {
                throw BridgeFailure("recovery_required", "Unexpected undo document")
            }
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
        for (path, target) in links {
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
                throw BridgeFailure("recovery_required", "Invalid undo link location: \(path)")
            }
            let url = directory.appendingPathComponent(path)
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
            let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
            guard parent == root || parent.hasPrefix(root + "/") else {
                throw BridgeFailure("recovery_required", "Undo link parent changed")
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            if let attributes {
                guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
                    throw BridgeFailure("recovery_required", "Undo link was replaced: \(url.path)")
                }
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
        }
    }
}
