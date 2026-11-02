//
//  PortableMetadataTestSupport.swift
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

struct MetadataFixture {
    let root: URL
    let bottle: URL
    let executable: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisky-metadata-\(UUID())")
        bottle = root.appendingPathComponent("Bottle")
        executable = bottle.appendingPathComponent("drive_c/Games/Test/game.exe")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x4D, 0x5A]).write(to: executable)
        struct Pin: Encodable {
            let name: String
            let url: URL
            let removable: Bool
        }
        struct Info: Encodable {
            let name: String
            let pins: [Pin]
            let blocklist: [URL]
        }
        struct Metadata: Encodable {
            let info: Info
        }
        let metadata = Metadata(info: Info(
            name: "Metadata Test",
            pins: [Pin(name: "Test", url: executable, removable: false)],
            blocklist: []
        ))
        try PropertyListEncoder().encode(metadata)
            .write(to: bottle.appendingPathComponent("Metadata.plist"))
    }

    var workspace: ApplicationWorkspace {
        ApplicationWorkspace(containers: [bottle])
    }

    var entryID: String {
        "pinned:\(executable.path)"
    }

    var params: [String: JSONValue] {
        [
            "container": .string(bottle.path),
            "entryID": .string(entryID)
        ]
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor func metadataService() -> LibraryMetadataService {
    LibraryMetadataService(jobs: BridgeJobStore(), networkAccess: {})
}

let pngPixel = Data(base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAYAAAB/qH1jAAAAEklEQVR4nGP43+HyHxkzoAsAAHyRFlERVA2OAAAAAElFTkSuQmCC"
) ?? Data()

@MainActor func waitForMetadataJob(_ started: JSONValue, jobs: BridgeJobStore) async throws -> JSONValue {
    let id = try #require(started.object?["jobID"]?.string)
    for _ in 0 ..< 150 {
        let job = try jobs.call("jobs.get", params: ["jobID": .string(id)])
        if job.object?["status"] == .string("completed") {
            return try #require(job.object?["result"])
        }
        if job
            .object?["status"] == .string("failed") {
            throw BridgeFailure("test_job_failed", String(describing: job))
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw BridgeFailure("test_timeout", "Metadata fixture job timed out")
}

let nextMoeGuideFixture = """
{"id":"1","work_id":"4","source":"example","source_url":"https://fixture.example/guide",
 "source_author":"Author","lang":"ja","release":null,"characters":[],"ending_count":1,
 "save_count":1,"segment_count":1,"work_route_hints":true,"work_content_limit":"sfw",
 "updated_at":"2026-01-01T00:00:00Z"}
"""
