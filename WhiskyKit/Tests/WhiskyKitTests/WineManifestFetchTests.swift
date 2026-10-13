//
//  WineManifestFetchTests.swift
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
import SemanticVersion
@testable import WhiskyKit
import XCTest

private final class ManifestStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var status = 200
    private var requests: [URL] = []

    func set(data: Data, status: Int = 200) {
        lock.lock()
        defer { lock.unlock() }
        self.data = data
        self.status = status
    }

    func response(for url: URL) -> (Data, Int) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(url)
        return (data, status)
    }

    func requestedURLs() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private final class ManifestStubProtocol: URLProtocol, @unchecked Sendable {
    static let state = ManifestStubState()
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (data, status) = Self.state.response(for: url)
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class WineManifestFetchTests: XCTestCase {
    func testCacheManualRefreshAndHTTPFailurePreserveValidManifest() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ManifestStubProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let asset = "https://github.com/daydalek/ge-proton-macos-wine-poc/releases/download/v0.1.0/Libraries.tar.gz"
        func encoded(_ patch: Int) throws -> Data {
            try PropertyListEncoder().encode(WhiskyWineVersion(
                version: SemanticVersion(11, 0, patch), sha256: String(repeating: "a", count: 64), downloadURL: asset
            ))
        }
        try ManifestStubProtocol.state.set(data: encoded(1))
        let first = try await DistributionConfig.fetchWineManifest(session: session, useCache: false)
        XCTAssertEqual(first.version.patch, 1)
        try ManifestStubProtocol.state.set(data: encoded(2))
        let cached = try await DistributionConfig.fetchWineManifest(session: session)
        XCTAssertEqual(cached.version.patch, 1)
        XCTAssertEqual(ManifestStubProtocol.state.requestedURLs().count, 1)
        let fresh = try await DistributionConfig.fetchWineManifest(session: session, useCache: false)
        XCTAssertEqual(fresh.version.patch, 2)
        ManifestStubProtocol.state.set(data: Data(), status: 403)
        do {
            _ = try await DistributionConfig.fetchWineManifest(session: session, useCache: false)
            XCTFail("Expected HTTP failure")
        } catch {
            XCTAssertEqual(error as? DistributionConfig.WineManifestError, .httpStatus(403))
        }
        let retained = try await DistributionConfig.fetchWineManifest(session: session)
        XCTAssertEqual(retained.version.patch, 2)
        let urls = ManifestStubProtocol.state.requestedURLs()
        XCTAssertEqual(urls.count, 3)
        XCTAssertTrue(urls.allSatisfy { $0.absoluteString == DistributionConfig.versionPlistURL })
    }
}
