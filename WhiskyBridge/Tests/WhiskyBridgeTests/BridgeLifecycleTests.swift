//
//  BridgeLifecycleTests.swift
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
@testable import WhiskyApplication
import WhiskyBridgeProtocol
import WhiskyCore

@Suite("WhiskyBridge Container Lifecycle & Framing Tests")
struct BridgeLifecycleTests {
    @Test("Verify container catalogue scan and metadata serialization")
    @MainActor
    func containerCatalogueSerialization() async throws {
        let fixture = try VirtualPrefixFixture()
        defer { fixture.cleanup() }

        let bottle1 = try fixture.createBottle(name: "TestBottleAlpha")
        let bottle2 = try fixture.createBottle(name: "TestBottleBeta")

        #expect(FileManager.default.fileExists(atPath: bottle1.path))
        #expect(FileManager.default.fileExists(atPath: bottle2.path))
        #expect(FileManager.default.fileExists(atPath: bottle1.appendingPathComponent("Metadata.plist").path))
        #expect(FileManager.default.fileExists(atPath: bottle2.appendingPathComponent("Metadata.plist").path))

        let workspace = fixture.createWorkspace(bottles: [bottle1, bottle2])
        let catalogue = try workspace.catalogue()
        #expect(catalogue.count == 2)

        let names = catalogue.map(\.name)
        #expect(names.contains("TestBottleAlpha"))
        #expect(names.contains("TestBottleBeta"))

        for record in catalogue {
            #expect(record.available == true)
            #expect(record.path == bottle1.path || record.path == bottle2.path)
        }

        // Verify full IPC dispatch via ApplicationService
        let service = ApplicationService(workspace: workspace)
        let request = BridgeRequest(id: "req-catalogue-1", method: "workspace.containers")
        let response = await service.respond(request)

        #expect(response.error == nil)
        #expect(response.id == "req-catalogue-1")

        guard let result = response.result else {
            Issue.record("Expected non-nil result from workspace.containers response")
            return
        }

        let decodedRecords = try result.decoded([ContainerRecord].self)
        #expect(decodedRecords.count == 2)
        #expect(decodedRecords.map(\.name).sorted() == ["TestBottleAlpha", "TestBottleBeta"].sorted())
    }

    @Test("Verify NDJSON framing respects 1MB maximum frame threshold", arguments: [
        1_024,
        64 * 1_024,
        1_024 * 1_024 // 1MB maximum frame threshold
    ])
    func framingBoundaries(frameSize: Int) throws {
        var framer = BridgeFramer()
        var payload = Data(repeating: 0x61, count: frameSize)
        payload.append(0x0A) // newline delimiter '\n'

        let frames = try framer.append(payload)
        #expect(frames.count == 1)
        #expect(frames[0].count == frameSize)
        try framer.finish()
    }

    @Test("Verify oversize NDJSON frame triggers frame_too_large error")
    func oversizeFrameThrows() throws {
        var framer = BridgeFramer()
        let oversize = Data(repeating: 0x78, count: BridgeFramer.maximumFrameBytes + 1)

        #expect {
            try framer.append(oversize)
        } throws: { error in
            guard let failure = error as? BridgeFailure else { return false }
            return failure.code == "frame_too_large"
        }
    }

    @Test("Verify truncated NDJSON frame throws truncated_frame on stream finish")
    func truncatedFrameThrows() throws {
        var framer = BridgeFramer()
        let partialData = Data("{\"method\":\"test.partial\"".utf8)
        let frames = try framer.append(partialData)
        #expect(frames.isEmpty)

        #expect {
            try framer.finish()
        } throws: { error in
            guard let failure = error as? BridgeFailure else { return false }
            return failure.code == "truncated_frame"
        }
    }

    @Test("Verify VirtualPrefixFixture sandbox isolation and cleanup")
    func virtualPrefixFixtureIsolation() throws {
        let fixture = try VirtualPrefixFixture()
        let dir = fixture.tempDirectory
        #expect(FileManager.default.fileExists(atPath: dir.path))

        let bottle = try fixture.createBottle(name: "IsolatedBottle")
        #expect(FileManager.default.fileExists(atPath: bottle.path))

        fixture.cleanup()
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test("Verify catalogue handles missing container directory gracefully")
    func catalogueHandlesMissingContainer() throws {
        let fixture = try VirtualPrefixFixture()
        defer { fixture.cleanup() }

        let bottle = try fixture.createBottle(name: "ExistingBottle")
        let nonExistentBottle = fixture.tempDirectory.appendingPathComponent("MissingBottle")

        let workspace = fixture.createWorkspace(bottles: [bottle, nonExistentBottle])
        let catalogue = try workspace.catalogue()
        #expect(catalogue.count == 2)

        let existing = catalogue.first { $0.path == bottle.path }
        #expect(existing?.available == true)
        #expect(existing?.name == "ExistingBottle")

        let missing = catalogue.first { $0.path == nonExistentBottle.path }
        #expect(missing?.available == false)
        #expect(missing?.name == "MissingBottle")
    }
}
