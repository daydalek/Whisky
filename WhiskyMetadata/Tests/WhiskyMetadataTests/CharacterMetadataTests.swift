//
//  CharacterMetadataTests.swift
//  WhiskyMetadataTests
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

@Test func characterDetailsRespectOptOutAndPersistEmptyResults() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CharacterFixtureProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let provider = PublicGameMetadataProvider(source: .bangumi, session: session)
    let candidate = GameMetadata(source: .bangumi, sourceID: "42", title: "作品")
    let disabled = try await provider.details(for: candidate, includeCharacters: false)
    #expect(disabled.characters == nil)
    let fetched = try await provider.details(for: candidate, includeCharacters: true)
    #expect(fetched.characters == [])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = GameMetadataStore(directory: directory)
    try await store.save(fetched, for: "game")
    let saved = try #require(try await store.load(for: "game"))
    #expect(saved.characters == [])
}

@Test func alreadyFetchedCharactersDoNotUseTransportOrReplaceCandidateTitle() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CharacterFixtureProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let provider = PublicGameMetadataProvider(source: .bangumi, session: session)
    let candidate = GameMetadata(source: .bangumi, sourceID: "no-request", title: "New title", characters: [])
    let result = try await provider.details(for: candidate, includeCharacters: true)
    #expect(result == candidate)
}

private final class CharacterFixtureProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              url.path == "/v0/subjects/42/characters",
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("[]".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor CharacterRequestCounter {
    var count = 0
    func increment() { count += 1 }
}

@Test func concurrentCharacterRequestsShareEmptyResult() async throws {
    let gate = SourceGatekeeper(minInterval: 0)
    let counter = CharacterRequestCounter()
    try await withThrowingTaskGroup(of: [GameCharacter].self) { group in
        for _ in 0..<8 {
            group.addTask {
                try await gate.characters("same-game") {
                    await counter.increment()
                    try await Task.sleep(for: .milliseconds(20))
                    return []
                }
            }
        }
        for try await result in group { #expect(result.isEmpty) }
    }
    #expect(await counter.count == 1)
}

@Test func failedCharacterRefreshHasShortCooldown() async {
    let gate = SourceGatekeeper(minInterval: 0)
    let counter = CharacterRequestCounter()
    for _ in 0..<3 {
        do {
            _ = try await gate.characters("timeout") {
                await counter.increment()
                throw URLError(.timedOut)
            }
            Issue.record("Expected timeout")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        } catch { Issue.record(error) }
    }
    #expect(await counter.count == 1)
}

@Test func characterRateLimitAlsoCoolsDownSearches() async {
    let gate = SourceGatekeeper(minInterval: 0)
    let counter = CharacterRequestCounter()
    do {
        _ = try await gate.characters("rate-limited") {
            throw ProviderError.rateLimited(429, retryAfter: 60)
        }
        Issue.record("Expected rate limit")
    } catch {}
    do {
        _ = try await gate.search("other-query") {
            await counter.increment()
            return []
        }
        Issue.record("Expected shared cooldown")
    } catch {}
    #expect(await counter.count == 0)
}

@Test func portraitPacingHonorsRemoteCooldown() async {
    let gate = SourceGatekeeper(minInterval: 0)
    let counter = CharacterRequestCounter()
    do {
        try await gate.paced { throw ProviderError.rateLimited(503, retryAfter: 60) }
        Issue.record("Expected remote cooldown")
    } catch {}
    do {
        try await gate.paced { await counter.increment() }
        Issue.record("Expected cooldown to suppress next download")
    } catch {}
    #expect(await counter.count == 0)
}
