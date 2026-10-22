//
//  PortableRouteCompatibilityTests.swift
//  WhiskyNativeBridgeTests
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
import WhiskyApplication
import WhiskyBridgeProtocol
import WhiskyCore
import WhiskyKit
@testable import WhiskyNativeBridge

@Test @MainActor func portableLifecycleRoutesRemainReadableByNativeGameRouting() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("route-compat-" + UUID().uuidString)
    let container = root.appendingPathComponent("Bottle")
    let registry = root.appendingPathComponent("BottleVM.plist")
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try PropertyListSerialization.data(
        fromPropertyList: ["info": ["name": "Route fixture"]],
        format: .binary,
        options: 0
    )
    .write(to: container.appendingPathComponent("Metadata.plist"))
    try PropertyListSerialization.data(
        fromPropertyList: ["paths": [["relative": container.absoluteString]]],
        format: .binary,
        options: 0
    ).write(to: registry)
    let routesURL = root.appendingPathComponent("GameRouting.plist")
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let routes: [String: Any] = [
        "10": container.path,
        "20": ["bottle": container.path, "lastLaunched": date]
    ]
    try PropertyListSerialization.data(fromPropertyList: routes, format: .binary, options: 0).write(to: routesURL)
    let parent = root.appendingPathComponent("Moved")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    let service = ApplicationService(workspace: ApplicationWorkspace(registry: registry))
    let started = try await service.call("bottle.move", params: [
        "container": .string(container.path), "destination": .string(parent.path)
    ])
    let id = try #require(started.object?["jobID"]?.string)
    var finished = false
    for _ in 0 ..< 200 {
        let state = try service.jobs.call("jobs.get", params: ["jobID": .string(id)])
        if state.object?["status"] == .string("completed") {
            finished = true
            break
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(finished)
    let native = GameRouting(url: routesURL)
    let expected = parent.appendingPathComponent("Bottle").resolvingSymlinksInPath().path
    #expect(native.bottleURL(forAppId: 10)?.path == expected)
    #expect(native.bottleURL(forAppId: 20)?.path == expected)
    #expect(native.lastLaunched(forAppId: 10) == nil)
    #expect(native.lastLaunched(forAppId: 20) == date)
    await service.shutdown()
}
