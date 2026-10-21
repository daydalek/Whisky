//
//  BottleCreationServiceTests.swift
//  WhiskyKit
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
@testable import WhiskyKit

@Suite("Shared Bottle creation")
struct BottleCreationServiceTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("creation-service-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test @MainActor func persistsInitializedPrefixAndRegistry() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("new")
        let registryURL = root.appendingPathComponent("registry.plist")
        let result = try await BottleCreationService.create(
            name: "  新容器  ",
            windowsVersion: .win11,
            parentDirectory: root,
            destinationDirectory: destination,
            registry: BottleData(entriesFile: registryURL),
            runtimeIsAvailable: { true },
            validateLocation: { _ in .valid },
            bootstrapPrefix: { bottle in
                try FileManager.default.createDirectory(
                    at: bottle.url.appendingPathComponent("drive_c"),
                    withIntermediateDirectories: true
                )
            }
        )
        #expect(result.bottle.settings.name == "新容器")
        let persisted = try PropertyListDecoder().decode(
            BottleSettings.self,
            from: Data(contentsOf: destination.appendingPathComponent("Metadata.plist"))
        )
        #expect(persisted.name == "新容器" && persisted.windowsVersion == .win11)
        #expect(BottleData(entriesFile: registryURL).paths.contains { $0.path == destination.path })
    }

    @Test @MainActor func rejectsExistingDestinationAndKeepsItsData() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        await #expect(throws: BottleCreationServiceError.self) {
            try await BottleCreationService.create(
                name: "New",
                windowsVersion: .win10,
                parentDirectory: root,
                destinationDirectory: destination,
                registry: BottleData(entriesFile: root
                    .appendingPathComponent("registry.plist")),
                runtimeIsAvailable: { true },
                validateLocation: { _ in .valid },
                bootstrapPrefix: { _ in
                    Issue.record("Existing prefix reached bootstrap")
                }
            )
        }
        #expect(try Data(contentsOf: marker) == Data("keep".utf8))
    }

    @Test @MainActor func failedBootstrapRemovesOnlyOwnedPrefix() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("new")
        let registryURL = root.appendingPathComponent("registry.plist")
        await #expect(throws: CocoaError.self) {
            try await BottleCreationService.create(
                name: "New",
                windowsVersion: .win10,
                parentDirectory: root,
                destinationDirectory: destination,
                registry: BottleData(entriesFile: registryURL),
                runtimeIsAvailable: { true },
                validateLocation: { _ in .valid },
                bootstrapPrefix: { _ in throw CocoaError(.fileWriteUnknown) }
            )
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(BottleData(entriesFile: registryURL).paths.isEmpty)
    }

    @Test @MainActor func runtimeMissingLeavesDestinationUncreated() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("new")
        await #expect(throws: BottleCreationServiceError.self) {
            try await BottleCreationService.create(
                name: "New",
                windowsVersion: .win10,
                parentDirectory: root,
                destinationDirectory: destination,
                registry: BottleData(entriesFile: root
                    .appendingPathComponent("registry.plist")),
                runtimeIsAvailable: { false },
                validateLocation: { _ in
                    Issue.record("Unexpected filesystem preflight")
                    return .valid
                },
                bootstrapPrefix: { _ in
                    Issue.record("Unexpected Wine invocation")
                }
            )
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}

@Test @MainActor func everyFrontendUsesTheSamePerBottleQuitPolicy() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("quit-policy-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let inherited = Bottle(bottleUrl: root.appendingPathComponent("inherit"))
    let always = Bottle(bottleUrl: root.appendingPathComponent("always"))
    let never = Bottle(bottleUrl: root.appendingPathComponent("never"))
    inherited.settings.killOnQuit = .inherit
    always.settings.killOnQuit = .alwaysKill
    never.settings.killOnQuit = .neverKill
    var terminated: [URL] = [], cleared: [URL] = []
    ApplicationShutdownService.apply(
        to: [inherited, always, never],
        globalKill: false,
        terminate: { terminated.append($0.url) },
        clearProcesses: { cleared.append($0) },
        temporaryFiles: []
    )
    #expect(terminated == [always.url] && cleared == terminated)
    terminated = []
    cleared = []
    ApplicationShutdownService.apply(
        to: [inherited, always, never],
        globalKill: true,
        terminate: { terminated.append($0.url) },
        clearProcesses: { cleared.append($0) },
        temporaryFiles: []
    )
    #expect(terminated == [inherited.url, always.url] && cleared == terminated)
}
