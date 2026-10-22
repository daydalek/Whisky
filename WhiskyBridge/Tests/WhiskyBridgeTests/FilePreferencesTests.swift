//
//  FilePreferencesTests.swift
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
import Testing
@testable import WhiskyApplication
import WhiskyBridgeProtocol
import WhiskyCore

@Test @MainActor func filePreferencesReloadPreserveUnknownKeysAndValidateWrites() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("whisky-preferences-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("config/whisky/preferences.plist")
    let fallback = root.appendingPathComponent("Bottles")
    let first = PreferencesService(fileURL: path, defaultBottleDirectory: fallback)
    let second = PreferencesService(fileURL: path, defaultBottleDirectory: fallback)
    let initial = try first.call("preferences.read", params: [:])
    #expect(initial.object?["defaultBottleLocation"] == .string(fallback.path))
    var raw: [String: Any] = ["futurePreference": ["keep": "opaque"]]
    try PropertyListSerialization.data(fromPropertyList: raw, format: .binary, options: 0).write(to: path)
    _ = try first.call("preferences.set", params: ["key": .string("offlineMode"), "value": .bool(true)])
    _ = try second.call("preferences.set", params: ["key": .string("librarySort"), "value": .string("name")])
    let restarted = PreferencesService(fileURL: path, defaultBottleDirectory: fallback)
    let read = try restarted.call("preferences.read", params: [:])
    #expect(read.object?["offlineMode"] == .bool(true))
    #expect(read.object?["librarySort"] == .string("name"))
    raw = try #require(PropertyListSerialization.propertyList(
        from: Data(contentsOf: path), format: nil
    ) as? [String: Any])
    #expect((raw["futurePreference"] as? [String: String])?["keep"] == "opaque")
    let before = try Data(contentsOf: path)
    #expect(throws: BridgeFailure.self) { try first.call("preferences.set", params: [
        "key": .string("offlineMode"), "value": .string("false")
    ]) }
    #expect(try Data(contentsOf: path) == before)
    try Data("corrupt".utf8).write(to: path)
    #expect(throws: (any Error).self) { try second.call("preferences.set", params: [
        "key": .string("offlineMode"), "value": .bool(false)
    ]) }
    #expect(try Data(contentsOf: path) == Data("corrupt".utf8))
}

@Test func linuxPreferencePathsFollowAbsoluteXDGDirectories() {
    let home = URL(fileURLWithPath: "/tmp/fixture-home")
    #expect(HostPaths.preferences(
        home: home, environment: [:]
    ).path == "/tmp/fixture-home/.config/whisky/preferences.plist")
    #expect(HostPaths.preferences(
        home: home, environment: ["XDG_CONFIG_HOME": "relative"]
    ).path == "/tmp/fixture-home/.config/whisky/preferences.plist")
    #expect(HostPaths.preferences(
        home: home, environment: ["XDG_CONFIG_HOME": "/tmp/chosen"]
    ).path == "/tmp/chosen/whisky/preferences.plist")
}
