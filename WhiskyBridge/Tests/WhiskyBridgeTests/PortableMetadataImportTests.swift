//
//  PortableMetadataImportTests.swift
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
import WhiskyApplication
import WhiskyBridgeProtocol
import WhiskyCore
import WhiskyMetadata
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Test @MainActor func portableMetadataApplyImportCoverAndClear() async throws {
    let fixture = try MetadataFixture()
    defer { fixture.remove() }
    let service = metadataService()
    let entry = try await fixture.workspace.entry(fixture.params)
    let store = GameMetadataStore(directory: entry.metadataDirectory, networkAccess: {})
    let metadata = GameMetadata(
        source: .bangumi,
        sourceID: "42",
        title: "测试游戏",
        originalTitle: "Test Game",
        summary: "Summary",
        developer: "Studio",
        releaseDate: "2020-01-01"
    )

    var params = fixture.params
    var snapshot = try #require(try JSONValue.encoded(metadata).object)
    snapshot["includeCharacters"] = .bool(false)
    params["metadata"] = .object(snapshot)
    _ = try await service.call(
        "metadata.apply",
        params: params,
        workspace: fixture.workspace
    )
    let saved = try #require(try await store.load(for: entry.metadataIdentity))
    #expect(saved.title == "测试游戏")
    #expect(saved.source == .bangumi)

    let cover = fixture.root.appendingPathComponent("cover.png")
    try pngPixel.write(to: cover)
    var coverParams = fixture.params
    coverParams["path"] = .string(cover.path)
    _ = try await service.call(
        "metadata.cover.import",
        params: coverParams,
        workspace: fixture.workspace
    )
    let settings = try await store.loadCoverSettings(for: entry.metadataIdentity)
    #expect(settings.useCustomCover)
    #expect(store.customCoverURL(for: settings) != nil)

    _ = try await service.call(
        "metadata.cover.reset",
        params: fixture.params,
        workspace: fixture.workspace
    )
    #expect(try await !store.loadCoverSettings(for: entry.metadataIdentity).useCustomCover)

    _ = try await service.call(
        "metadata.clear",
        params: fixture.params,
        workspace: fixture.workspace
    )
    #expect(try await store.load(for: entry.metadataIdentity) == nil)
}
