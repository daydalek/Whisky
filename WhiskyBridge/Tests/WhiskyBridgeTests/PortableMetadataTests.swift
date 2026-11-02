//
//  PortableMetadataTests.swift
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

@Test @MainActor func metadataHydrationStagesDetailsAndPreservesCompleteSnapshots() async throws {
    let fixture = try MetadataFixture()
    defer { fixture.remove() }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MetadataHydrationProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let jobs = BridgeJobStore()
    let service = LibraryMetadataService(jobs: jobs, session: session, networkAccess: {})
    var draft = GameMetadataRecord(defaultSource: .steam)
    draft.bindings["steam"] = "7"
    draft.snapshots["steam"] = GameMetadata(source: .steam, sourceID: "7", title: "Search hit")
    var params = fixture.params
    params["hydrate"] = .bool(true)
    params["background"] = .bool(true)
    params["sources"] = .array([.string("steam")])
    params["record"] = try .encoded(draft)
    let started = try await service.call("metadata.configuration.save", params: params, workspace: fixture.workspace)
    #expect(started.object?["jobID"]?.string != nil)
    let saved = try await waitForMetadataJob(started, jobs: jobs)
    params["background"] = .bool(false)
    let complete = try #require(saved.object?["record"]).decoded(GameMetadataRecord.self)
    #expect(complete.snapshots["steam"]?.summary == "Full summary")
    #expect(complete.snapshots["steam"]?.developer == "Developer")

    // A repeat search hit must neither fetch again nor replace full details.
    let offline = LibraryMetadataService(
        jobs: BridgeJobStore(),
        session: session,
        networkAccess: { throw URLError(.notConnectedToInternet) }
    )
    draft.manualTitle = "Local"
    params["record"] = try .encoded(draft)
    let repeated = try await offline.call("metadata.configuration.save", params: params, workspace: fixture.workspace)
    let retained = try #require(repeated.object?["record"]).decoded(GameMetadataRecord.self)
    #expect(retained.snapshots["steam"]?.summary == "Full summary")
    #expect(retained.manualTitle == "Local")

    draft.bindings["steam"] = "8"
    draft.snapshots["steam"] = GameMetadata(source: .steam, sourceID: "8", title: "New search hit")
    draft.manualTitle = "Uncommitted"
    params["record"] = try .encoded(draft)
    do {
        _ = try await offline.call("metadata.configuration.save", params: params, workspace: fixture.workspace)
        Issue.record("Hydration failure committed the draft")
    } catch {}
    let afterFailure = try await offline.call(
        "metadata.configuration.get",
        params: fixture.params,
        workspace: fixture.workspace
    )
    let unchanged = try #require(afterFailure.object?["record"]).decoded(GameMetadataRecord.self)
    #expect(unchanged.bindings["steam"] == "7")
    #expect(unchanged.snapshots["steam"]?.summary == "Full summary")
    #expect(unchanged.manualTitle == "Local")

    // Disabled sources still permit a local pending binding with no transport.
    params["sources"] = .array([])
    let pending = try await offline.call("metadata.configuration.save", params: params, workspace: fixture.workspace)
    let pendingRecord = try #require(pending.object?["record"]).decoded(GameMetadataRecord.self)
    #expect(pendingRecord.bindings["steam"] == "8")
    var refreshParams = fixture.params
    refreshParams["background"] = .bool(true)
    refreshParams["sources"] = .array([])
    let refreshJob = try await service.call("metadata.refresh", params: refreshParams, workspace: fixture.workspace)
    let refreshed = try await waitForMetadataJob(refreshJob, jobs: jobs)
    #expect(refreshed.object?["record"]?.object?["bindings"]?.object?["steam"] == .string("8"))
}

private class MetadataHydrationProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              url.host == "store.steampowered.com", url.path == "/api/appdetails",
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = #"{"7":{"success":true,"data":{"name":"Complete","short_description":"Full summary","developers":["Developer"]}}}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Test @MainActor func applicationDispatchesPreferenceBatchAndRejectsNoncanonicalBindings() async throws {
    let fixture = try MetadataFixture()
    defer { fixture.remove() }
    let preferences = PreferencesService(
        fileURL: fixture.root.appendingPathComponent("preferences.plist"),
        defaultBottleDirectory: fixture.root
    )
    let application = ApplicationService(workspace: fixture.workspace, preferences: preferences)
    let values = try await application.call("preferences.setMany", params: ["values": .object([
        "libraryMetadataDefaultSource": .string("vndb"),
        "libraryOnboardingCompleted": .bool(true)
    ])])
    #expect(values.object?["libraryMetadataDefaultSource"] == .string("vndb"))
    #expect(values.object?["libraryOnboardingCompleted"] == .bool(true))
    let reread = try await application.call("preferences.read", params: [:])
    #expect(reread.object?["libraryMetadataDefaultSource"] == .string("vndb"))
    for (source, id) in [("bangumi", "0001"), ("vndb", "v0001"), ("steam", "0"), ("ymgal", "01")] {
        var record = GameMetadataRecord()
        record.bindings[source] = id
        var params = fixture.params
        params["record"] = try .encoded(record)
        do {
            _ = try await application.call("metadata.configuration.save", params: params)
            Issue.record("Noncanonical binding accepted: \(source):\(id)")
        } catch let error as BridgeFailure {
            #expect(error.code == "invalid_params")
        }
    }
    let absent = try await application.call("metadata.configuration.get", params: fixture.params)
    #expect(absent.object?["hasRecord"] == .bool(false))
}

@Test @MainActor func nextMoeMetadataPreferencesAreAcceptedAndPersisted() throws {
    let fixture = try MetadataFixture()
    defer { fixture.remove() }
    let preferences = PreferencesService(
        fileURL: fixture.root.appendingPathComponent("preferences.plist"),
        defaultBottleDirectory: fixture.root
    )
    let defaults = try preferences.call("preferences.read", params: [:])
    #expect(defaults.object?["libraryMetadataEnabledSources"]?.string?.contains("nextmoe") == true)
    _ = try preferences.call("preferences.setMany", params: ["values": .object([
        "libraryMetadataDefaultSource": .string("nextmoe"),
        "libraryMetadataSummarySource": .string("nextmoe"),
        "libraryMetadataEnabledSources": .string("vndb,nextmoe")
    ])])
    let saved = try preferences.call("preferences.read", params: [:])
    #expect(saved.object?["libraryMetadataDefaultSource"] == .string("nextmoe"))
    #expect(saved.object?["libraryMetadataSummarySource"] == .string("nextmoe"))
    #expect(saved.object?["libraryMetadataEnabledSources"] == .string("vndb,nextmoe"))
}

@Test @MainActor func metadataConfigurationDraftRefreshFailureAndPresentation() async throws {
    let fixture = try MetadataFixture()
    defer { fixture.remove() }
    let preferences = PreferencesService(
        fileURL: fixture.root.appendingPathComponent("prefs"),
        defaultBottleDirectory: fixture.root
    )
    _ = try preferences.call("preferences.setMany", params: ["values": .object([
        "libraryMetadataDefaultSource": .string("vndb"),
        "libraryMetadataCoverSource": .string("steam"),
        "libraryMetadataEnabledSources": .string(""),
        "libraryOnboardingCompleted": .bool(true)
    ])])
    let jobs = BridgeJobStore()
    let service = LibraryMetadataService(
        jobs: jobs,
        preferences: preferences,
        networkAccess: { throw URLError(.notConnectedToInternet) }
    )
    let empty = try await service.call(
        "metadata.configuration.get",
        params: fixture.params,
        workspace: fixture.workspace
    )
    #expect(empty.object?["hasRecord"] == .bool(false))
    #expect(empty.object?["capabilities"]?.object?["nextmoe"]?.object?["characters"] == .bool(true))
    #expect(empty.object?["capabilities"]?.object?["nextmoe"]?.object?["refresh"] == .bool(true))
    var record = try #require(empty.object?["record"]).decoded(GameMetadataRecord.self)
    #expect(record.defaultSource == .vndb)
    #expect(record.categorySources["cover"] == .steam)
    record.bindings["vndb"] = "v1"
    record.snapshots["vndb"] = GameMetadata(source: .vndb, sourceID: "v1", title: "Saved")
    record.manualTitle = "Manual"
    var params = fixture.params
    params["record"] = try .encoded(record)
    _ = try await service.call("metadata.configuration.save", params: params, workspace: fixture.workspace)
    let entry = try await fixture.workspace.entry(fixture.params)
    #expect(try LibraryPresentation.load(for: entry).metadata?.title == "Manual")
    let refreshed = try await service.call("metadata.refresh", params: fixture.params, workspace: fixture.workspace)
    #expect(refreshed.object?["errors"]?.object?["vndb"]?.string != nil)
    let retained = try #require(refreshed.object?["record"]).decoded(GameMetadataRecord.self)
    #expect(retained.snapshots["vndb"]?.title == "Saved")
    #expect(retained.manualTitle == "Manual")
    do {
        _ = try preferences.call("preferences.setMany", params: ["values": .object([
            "libraryOnboardingCompleted": .bool(false), "libraryMetadataDefaultSource": .string("bogus")
        ])])
        Issue.record("Invalid source accepted")
    } catch {}
    let values = try preferences.call("preferences.read", params: [:])
    #expect(values.object?["libraryOnboardingCompleted"] == .bool(true))
    #expect(values.object?["libraryMetadataEnabledSources"] == .string(""))
    var searchParams = fixture.params
    searchParams["query"] = .string("Must not search")
    let search = try await service.call("metadata.search", params: searchParams, workspace: fixture.workspace)
    let result = try await waitForMetadataJob(search, jobs: jobs)
    #expect(result.object?["results"] == .array([]))
    searchParams["sources"] = .array([])
    let explicit = try await service.call("metadata.search", params: searchParams, workspace: fixture.workspace)
    #expect(try await waitForMetadataJob(explicit, jobs: jobs).object?["results"] == .array([]))
}

/// A complete 4 × 2 PNG with an opaque orange fill.
