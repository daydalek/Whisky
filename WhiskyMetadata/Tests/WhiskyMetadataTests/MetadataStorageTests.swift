//
//  MetadataStorageTests.swift
//  WhiskyMetadata
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
import WhiskyCore
@testable import WhiskyMetadata
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private let coverBytes = Data(base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAYAAAB/qH1jAAAAEklEQVR4nGP43+HyHxkzoAsAAHyRFlERVA2OAAAAAElFTkSuQmCC"
) ?? Data()

@Test(arguments: [
    "/9j/4AAQSkZJRgABAQAAAAAAAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCw" +
        "kJDRENDg8QEBEQCgwSExIQEw8QEBD/2wBDAQMDAwQDBAgEBAgQCwkLEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ" +
        "EBAQEBAQEBAQEBAQEBAQEBAQEBAQEBD/wAARCAACAAQDAREAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAAB//EAB" +
        "QQAQAAAAAAAAAAAAAAAAAAAAD/xAAVAQEBAAAAAAAAAAAAAAAAAAAICf/EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAM" +
        "AwEAAhEDEQA/AHhPom3/2Q==",
    "R0lGODlhBAACAPAAAP+lAAAAACH5BAAAAAAAIf8LSW1hZ2VNYWdpY2sOZ2FtbWE9MC40NTQ1NDUALAAAAAAEAAIAAAIDhG8FADs=",
    "UklGRjwAAABXRUJQVlA4IDAAAADQAQCdASoEAAIAAgA0JaACdLoB+AADsAD+72SX/u837eb9vN/w0f/PTNeYP6aAAAA="
])
func nativeCoverDecoderSupportsJPEGAndGIFAndWebP(_ encoded: String) throws {
    let bytes = try #require(Data(base64Encoded: encoded))
    let dimensions = try #require(MetadataImage.dimensions(bytes))
    #expect(dimensions.width == 4 && dimensions.height == 2)
}

@Test func nativeImageDecoderValidatesPixelsAndCustomCoverTransactions() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-cover-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = GameMetadataStore(directory: root)
    let settings = try await store.importCover(coverBytes, for: "game")
    let original = try #require(store.customCoverURL(for: settings))
    #expect(try await store.coverAspectRatio(for: "game", metadataCoverURL: nil) == 2)
    #expect(try Data(contentsOf: original) == coverBytes)
    await #expect(throws: (any Error).self) { try await store.importCover(Data(coverBytes.prefix(24)), for: "game") }
    #expect(try await store.loadCoverSettings(for: "game") == settings)
    #expect(FileManager.default.fileExists(atPath: original.path))
    let replaced = try await store.importCover(coverBytes, for: "game")
    #expect(replaced.customFileName != settings.customFileName)
    #expect(!FileManager.default.fileExists(atPath: original.path))
}

@Test func metadataClearAndCopyPreserveIndependentArtworkAndManualUnlinkMarkers() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-copy-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = GameMetadataStore(directory: root.appendingPathComponent("source"))
    let target = GameMetadataStore(directory: root.appendingPathComponent("target"))
    let game = GameMetadata(source: .vndb, sourceID: "v1", title: "作品")
    try await store.save(game, for: "game")
    let settings = try await store.importCover(coverBytes, for: "game")
    try await store.remove(for: "game")
    #expect(try await store.load(for: "game") == nil)
    #expect(try await store.loadCoverSettings(for: "game") == settings)
    #expect(try await !store.allowsAutomaticMatch(for: "game"))
    try await store.copyEntry(for: "game", to: target, targetIdentity: "moved")
    #expect(try await !target.allowsAutomaticMatch(for: "moved"))
    let copied = try #require(target.customCoverURL(for: settings))
    #expect(try Data(contentsOf: copied) == coverBytes)
    #expect(try await target.coverAspectRatio(for: "moved", metadataCoverURL: nil) == 2)
}

@Test func injectedOfflinePolicyStopsEveryProviderAndCoverTransport() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CoverProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let policy: MetadataNetworkAccess = { throw URLError(.notConnectedToInternet) }
    for source in GameMetadataSource.allCases {
        let provider = PublicGameMetadataProvider(source: source, session: session, networkAccess: policy)
        await #expect(throws: URLError.self) { try await provider.search("test") }
        await #expect(throws: URLError.self) {
            try await provider.details(for: GameMetadata(source: source, sourceID: "1", title: "test"))
        }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-offline-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = GameMetadataStore(directory: root, networkAccess: policy)
    await #expect(throws: URLError.self) {
        try await store.cacheCover(
            from: #require(URL(string: "https://fixture.example/cover.png")),
            session: session
        )
    }
    try await store.save(GameMetadata(source: .bangumi, sourceID: "1", title: "Local"), for: "game")
    #expect(try await store.load(for: "game")?.title == "Local")
}

@Test func cachedRemoteCoversUseStableURLIdentityAcrossStores() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CoverProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-cache-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let remote = try #require(URL(string: "https://fixture.example/cover.png"))
    let store = GameMetadataStore(directory: root)
    try await store.cacheCover(from: remote, session: session)
    let cached = try #require(GameMetadataStore(directory: root).cachedCoverURL(for: remote))
    #expect(try Data(contentsOf: cached) == coverBytes)
    #expect(try await store.coverAspectRatio(for: "game", metadataCoverURL: remote) == 2)
}

private final class CoverProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "image/png"]
        )
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: coverBytes)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
