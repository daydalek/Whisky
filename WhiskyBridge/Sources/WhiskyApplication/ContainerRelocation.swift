//
//  ContainerRelocation.swift
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

/// Rewrites declared location fields while preserving opaque settings and relative identities.
/// Originals also cover symlinks so a failed move can restore the source tree.
struct ContainerRelocation {
    let source: URL
    let destination: URL
    private var files: [(String, Data)] = []
    private var links: [(String, String)] = []

    init(source: URL, destination: URL) {
        self.source = source
        self.destination = destination
    }

    mutating func apply(at directory: URL, name: String? = nil) throws {
        let metadata = directory.appendingPathComponent("Metadata.plist")
        let data = try ApplicationWorkspace.read(metadata)
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var document = try PropertyListSerialization.propertyList(from: data, format: &format) as? [String: Any],
              var info = document["info"] as? [String: Any], info["name"] is String
        else { throw CocoaError(.fileReadCorruptFile) }
        if let name {
            info["name"] = name
        }
        if let pins = info["pins"] as? [[String: Any]] {
            info["pins"] = pins.map { pin in
                var pin = pin
                if let url = pin["url"] {
                    pin["url"] = relocateURL(url)
                }
                return pin
            }
        }
        if let blocked = info["blocklist"] as? [Any] {
            info["blocklist"] = blocked.map(relocateURL)
        }
        document["info"] = info
        files.append(("Metadata.plist", data))
        try PropertyListSerialization.data(fromPropertyList: document, format: format, options: 0)
            .write(to: metadata, options: .atomic)
        guard source != destination else { return }
        try relocateFolders(at: directory)
        try relocateLinks(at: directory)
    }

    func restore(at directory: URL) throws {
        for (path, data) in files {
            try data.write(to: directory.appendingPathComponent(path), options: .atomic)
        }
        for (path, target) in links {
            let url = directory.appendingPathComponent(path)
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
        }
    }

    private func relocate(_ value: String) -> String {
        let root = source.path
        if value == root {
            return destination.path
        }
        return value.hasPrefix(root + "/") ? destination.path + value.dropFirst(root.count) : value
    }

    private func relocateURL(_ value: Any) -> Any {
        if var document = value as? [String: Any], let relative = document["relative"] as? String {
            document["relative"] = relocateURL(relative)
            return document
        }
        guard let string = value as? String else { return value }
        if string.hasPrefix("file:"), let url = URL(string: string), url.isFileURL {
            let path = relocate(url.path)
            return path == url.path ? string : URL(fileURLWithPath: path).absoluteString
        }
        return relocate(string)
    }

    private mutating func relocateFolders(at directory: URL) throws {
        let url = directory.appendingPathComponent("Folder Games.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try ApplicationWorkspace.read(url)
        guard var document = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CocoaError(.fileReadCorruptFile) }
        for key in [
            "roots",
            "assignedFolders",
            "excludedFolders",
            "knownFolders",
            "initializedRoots",
            "pendingMetadata"
        ] {
            if let paths = document[key] as? [String] {
                document[key] = paths.map(relocate)
            }
        }
        if let executables = document["executables"] as? [String: String] {
            document["executables"] = try executables.reduce(into: [String: String]()) { result, item in
                let key = relocate(item.key)
                guard result[key] == nil
                else { throw BridgeFailure("invalid_container", "Conflicting executable paths") }
                result[key] = relocate(item.value)
            }
        }
        files.append(("Folder Games.json", data))
        try JSONSerialization.data(withJSONObject: document).write(to: url, options: .atomic)
    }

    private mutating func relocateLinks(at directory: URL) throws {
        var scanError: (any Error)?
        guard let iterator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey],
            errorHandler: { _, error in scanError = error
                return false
            }
        )
        else { throw CocoaError(.fileReadUnknown) }
        for case let url as URL in iterator {
            try Task.checkCancellation()
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true else { continue }
            iterator.skipDescendants()
            let original = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            let target = relocate(original)
            guard target != original else { continue }
            let relative = String(url.path.dropFirst(directory.path.count + 1))
            links.append((relative, original))
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
        }
        if let scanError {
            throw scanError
        }
    }
}
