//
//  DisplayModeRegistryTests.swift
//  WhiskyKitTests
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

@Suite("Display mode registry synchronization")
@MainActor
struct DisplayModeRegistryTests {
    private enum Failure: Error { case rejected }

    private func makeBottle() throws -> Bottle {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Bottle(bottleUrl: root, inFlight: false, isAvailable: true)
    }

    @Test func disabledWithoutMarkerStampsFactoryDefaultWithoutImporting() async throws {
        let bottle = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle.url) }
        var imports = 0
        try await Wine.syncDisplayModeRegistry(
            bottle: bottle, emulateModeset: false, importer: { _, _ in imports += 1 }
        )
        #expect(imports == 0)
        #expect(DisplayModeRegistryState.load(from: bottle.url) == .factoryDefault)
    }

    @Test func enablingImportsEmulateModesetThenMatchingMarkerSkipsImport() async throws {
        let bottle = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle.url) }
        var documents: [String] = []
        let importer: Wine.RegistryImporter = { document, _ in documents.append(document) }
        try await Wine.syncDisplayModeRegistry(bottle: bottle, emulateModeset: true, importer: importer)
        #expect(documents.count == 1)
        #expect(documents.last?.contains(#"[HKEY_CURRENT_USER\Software\Wine\X11 Driver]"#) == true)
        #expect(documents.last?.contains(#""EmulateModeset"="Y""#) == true)
        #expect(DisplayModeRegistryState.load(from: bottle.url)?.emulateModeset == true)
        try await Wine.syncDisplayModeRegistry(bottle: bottle, emulateModeset: true, importer: importer)
        #expect(documents.count == 1)
    }

    @Test func disablingRemovesTheValue() async throws {
        let bottle = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle.url) }
        var documents: [String] = []
        let importer: Wine.RegistryImporter = { document, _ in documents.append(document) }
        try await Wine.syncDisplayModeRegistry(bottle: bottle, emulateModeset: true, importer: importer)
        try await Wine.syncDisplayModeRegistry(bottle: bottle, emulateModeset: false, importer: importer)
        #expect(documents.count == 2)
        #expect(documents.last?.contains(#""EmulateModeset"=-"#) == true)
        #expect(documents.last?.contains(#""EmulateModeset"="N""#) == false)
        #expect(DisplayModeRegistryState.load(from: bottle.url)?.emulateModeset == false)
    }

    @Test func failedImportRetainsMarkerForRetry() async throws {
        let bottle = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle.url) }
        await #expect(throws: Failure.rejected) {
            try await Wine.syncDisplayModeRegistry(
                bottle: bottle, emulateModeset: true, importer: { _, _ in throw Failure.rejected }
            )
        }
        #expect(DisplayModeRegistryState.load(from: bottle.url) == nil)
        var documents: [String] = []
        try await Wine.syncDisplayModeRegistry(
            bottle: bottle, emulateModeset: true, importer: { document, _ in documents.append(document) }
        )
        #expect(documents.count == 1)
        #expect(DisplayModeRegistryState.load(from: bottle.url)?.emulateModeset == true)
    }

    @Test func corruptMarkerLoadsAsNil() throws {
        let bottle = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle.url) }
        try Data("corrupt payload".utf8).write(to: DisplayModeRegistryState.markerURL(in: bottle.url))
        #expect(DisplayModeRegistryState.load(from: bottle.url) == nil)
    }
}

@Suite("Display mode failure detection")
struct DisplayModeFailureTests {
    @Test func badModeLineIsDetected() {
        let log = """
            0024:err:system:NtUserChangeDisplaySettings Changing L"\\\\.\\DISPLAY1" display settings \
            returned -2.
            """
        #expect(DisplayModeFailure.detect(logText: log))
    }

    @Test func otherNonzeroCodesAreDetected() {
        let log = "0024:err:system:NtUserChangeDisplaySettings Changing L\"X\" display settings returned -1."
        #expect(DisplayModeFailure.detect(logText: log))
    }

    @Test func successfulChangeIsNotDetected() {
        let log = "0024:trace:system:NtUserChangeDisplaySettings Changing L\"X\" display settings returned 0."
        #expect(!DisplayModeFailure.detect(logText: log))
    }

    @Test func unrelatedLinesAreNotDetected() {
        let log = """
            0024:err:module:import_dll Library missing.dll not found
            0024:fixme:system:NtUserDisplayConfigGetDeviceInfo unimplemented
            """
        #expect(!DisplayModeFailure.detect(logText: log))
    }

    @Test func lineWithoutReturnCodeIsNotDetected() {
        let log = "0024:trace:system:NtUserChangeDisplaySettings partial call"
        #expect(!DisplayModeFailure.detect(logText: log))
    }

    @Test func missingLogFileIsNotDetected() {
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString)
        #expect(!DisplayModeFailure.detect(logFileURL: url))
    }

    @Test func logFileTailIsScanned() throws {
        let url = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let log = """
            0024:fixme:whatever first line
            0024:err:system:NtUserChangeDisplaySettings Changing L"X" display settings returned -2.
            """
        try Data(log.utf8).write(to: url)
        #expect(DisplayModeFailure.detect(logFileURL: url))
    }
}
