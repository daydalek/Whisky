//
//  GameCoverSettingsTests.swift
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

import AppKit
import Foundation
import Testing
@testable import WhiskyKit

@Suite("Game cover settings")
struct GameCoverSettingsTests {
    @Test func customCoverSurvivesMetadataChangesAndMoves() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GameMetadataStore(directory: root.appendingPathComponent("source"))
        let target = GameMetadataStore(directory: root.appendingPathComponent("target"))
        let pixels = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let data = try #require(pixels.representation(using: .png, properties: [:]))
        let defaults = try await store.loadCoverSettings(for: "A")
        #expect(defaults == GameCoverSettings())
        var settings = try await store.importCover(data, for: "A")
        let firstURL = try #require(store.customCoverURL(for: settings))
        #expect(try await store.coverAspectRatio(for: "A", metadataCoverURL: nil) == 2)
        #expect(try Data(contentsOf: firstURL) == data)
        settings.zoom = 1.2
        settings.horizontalPosition = 0.8
        settings.useCustomCover = false
        try await store.saveCoverSettings(settings, for: "A")
        #expect(try await store.coverAspectRatio(for: "A", metadataCoverURL: nil) == nil)
        try await store.save(GameMetadata(source: .vndb, sourceID: "v1", title: "Game"), for: "A")
        try await store.remove(for: "A")
        #expect(try await store.loadCoverSettings(for: "A") == settings)
        #expect(try await store.loadCoverSettings(for: "B") == GameCoverSettings())
        try await store.copyEntry(for: "A", to: target, targetIdentity: "moved")
        #expect(try await target.loadCoverSettings(for: "moved") == settings)
        let copiedURL = try #require(target.customCoverURL(for: settings))
        #expect(try Data(contentsOf: copiedURL) == data)
        let replacement = try await store.importCover(data, for: "A")
        #expect(replacement.useCustomCover)
        #expect(replacement.zoom == 1.2)
        #expect(replacement.customFileName != settings.customFileName)
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
        #expect(FileManager.default.fileExists(atPath: copiedURL.path))
    }

    @Test func invalidImportPreservesSavedCover() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = GameMetadataStore(directory: root)
        var settings = GameCoverSettings()
        settings.zoom = 1.1
        try await store.saveCoverSettings(settings, for: "A")
        await #expect(throws: (any Error).self) {
            try await store.importCover(Data("invalid image".utf8), for: "A")
        }
        #expect(try await store.loadCoverSettings(for: "A") == settings)
        settings.customFileName = "../../outside"
        #expect(store.customCoverURL(for: settings) == nil)
    }
}
