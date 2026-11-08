//
//  VirtualPrefixFixture.swift
//  WhiskyBridgeTests
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
import Testing
@testable import WhiskyApplication
import WhiskyBridgeProtocol
import WhiskyCore

/// An in-memory/isolated virtual prefix test fixture providing zero-leak container
/// and registry sandboxing for bridge testing.
public struct VirtualPrefixFixture: Sendable {
    public let tempDirectory: URL
    public let registryURL: URL

    public init() throws {
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisky-test-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        self.registryURL = tempDirectory.appendingPathComponent("Registry.plist")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    /// Creates a synthetic bottle directory structure with a valid Metadata.plist.
    @discardableResult
    public func createBottle(name: String) throws -> URL {
        let bottleURL = tempDirectory.appendingPathComponent(name).resolvingSymlinksInPath()
        let driveC = bottleURL.appendingPathComponent("drive_c")
        try FileManager.default.createDirectory(at: driveC, withIntermediateDirectories: true)

        let metadata: [String: Any] = [
            "info": [
                "name": name,
                "pins": [] as [String],
                "blocklist": [] as [String]
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
        try data.write(to: bottleURL.appendingPathComponent("Metadata.plist"))
        return bottleURL
    }

    /// Creates an ApplicationWorkspace bound to this fixture's registry and explicit containers.
    public func createWorkspace(bottles: [URL]) -> ApplicationWorkspace {
        ApplicationWorkspace(registry: registryURL, containers: bottles)
    }

    /// Cleans up the temporary directory tree.
    public func cleanup() {
        try? FileManager.default.removeItem(at: tempDirectory)
    }
}
