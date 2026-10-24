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

}
