//
//  NetworkSettingsTests.swift
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
@testable import WhiskyKit
import XCTest

private final class OfflineRequestProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        XCTFail("Offline operation reached the network transport")
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

final class NetworkSettingsTests: XCTestCase {
    func testWineUpdatePreferencePersistsAndOfflineModeOverridesIt() async throws {
        let name = "NetworkSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(NetworkSettings.shouldCheckWineUpdates(defaults: defaults))
        defaults.set(false, forKey: NetworkSettings.wineUpdatesKey)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: name))
        XCTAssertFalse(NetworkSettings.shouldCheckWineUpdates(defaults: reopened))

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineRequestProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let disabled = await WhiskyWineInstaller.shouldUpdateWhiskyWine(defaults: reopened, session: session)
        XCTAssertFalse(disabled.0)

        defaults.set(true, forKey: NetworkSettings.wineUpdatesKey)
        XCTAssertTrue(NetworkSettings.shouldCheckWineUpdates(defaults: defaults))
        defaults.set(true, forKey: NetworkSettings.offlineModeKey)
        XCTAssertFalse(NetworkSettings.shouldCheckWineUpdates(defaults: defaults))
        let offline = await WhiskyWineInstaller.shouldUpdateWhiskyWine(defaults: defaults, session: session)
        XCTAssertFalse(offline.0)
        defaults.set(false, forKey: NetworkSettings.offlineModeKey)
        XCTAssertTrue(NetworkSettings.shouldCheckWineUpdates(defaults: defaults))
    }

    func testOfflineRequestsStopBeforeTransportAndLocalMetadataRemainsReadable() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: NetworkSettings.offlineModeKey)
        defaults.set(true, forKey: NetworkSettings.offlineModeKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: NetworkSettings.offlineModeKey)
            } else {
                defaults.removeObject(forKey: NetworkSettings.offlineModeKey)
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineRequestProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GameMetadataStore(directory: directory)
        let cover = try XCTUnwrap(URL(string: "https://example.com/cover.png"))
        let game = GameMetadata(source: .vndb, sourceID: "v1", title: "Local game", coverURL: cover)
        try await store.save(game, for: "local")
        let loaded = try await store.load(for: "local")
        XCTAssertEqual(loaded?.title, game.title)

        await expectOffline { _ = try await DistributionConfig.fetchWineManifest(session: session, useCache: false) }
        for source in [GameMetadataSource.bangumi, .vndb, .steam, .ymgal] {
            let provider = PublicGameMetadataProvider(source: source, session: session)
            await expectOffline { _ = try await provider.search("test") }
            await expectOffline { _ = try await provider.details(for: game) }
        }
        await expectOffline { try await store.cacheCover(from: cover, session: session) }
        let cachedCover = store.coverLocation(for: cover)
        try FileManager.default.createDirectory(
            at: cachedCover.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([1, 2, 3]).write(to: cachedCover)
        try await store.cacheCover(from: cover, session: session)
        XCTAssertEqual(store.cachedCoverURL(for: cover), cachedCover)
        await expectOffline { _ = try await Rosetta2.installRosetta() }
        await expectOffline {
            try await ResumableDownloader().download(from: cover, to: directory.appendingPathComponent("download"))
        }
    }

    private func expectOffline(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected offline error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }
}
