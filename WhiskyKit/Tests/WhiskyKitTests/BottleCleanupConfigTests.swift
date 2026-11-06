//
//  BottleCleanupConfigTests.swift
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

@testable import WhiskyKit
import XCTest

final class BottleCleanupConfigTests: XCTestCase {
    func testBottleCleanupConfigDefaultValues() {
        let config = BottleCleanupConfig()
        XCTAssertEqual(config.clipboardPolicy, .auto)
        XCTAssertEqual(config.clipboardThreshold, ClipboardManager.largeContentThreshold)
        XCTAssertEqual(config.killOnQuit, .inherit)
    }

    func testBottleCleanupConfigRoundTrip() throws {
        var config = BottleCleanupConfig()
        config.clipboardPolicy = .alwaysClear
        config.clipboardThreshold = 50_000
        config.killOnQuit = .alwaysKill

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(config)

        let decoder = PropertyListDecoder()
        let decoded = try decoder.decode(BottleCleanupConfig.self, from: data)

        XCTAssertEqual(decoded.clipboardPolicy, .alwaysClear)
        XCTAssertEqual(decoded.clipboardThreshold, 50_000)
        XCTAssertEqual(decoded.killOnQuit, .alwaysKill)
        XCTAssertEqual(decoded, config)
    }

    func testLegacyCloseWithProcessesPolicyDecodesLeniently() throws {
        // Legacy plist containing obsolete closeWithProcessesPolicy
        let legacyPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>clipboardPolicy</key>
            <string>warn</string>
            <key>clipboardThreshold</key>
            <integer>20000</integer>
            <key>killOnQuit</key>
            <string>never</string>
            <key>closeWithProcessesPolicy</key>
            <string>ask</string>
        </dict>
        </plist>
        """

        let decoder = PropertyListDecoder()
        let decoded = try decoder.decode(BottleCleanupConfig.self, from: Data(legacyPlist.utf8))

        XCTAssertEqual(decoded.clipboardPolicy, .alwaysWarn)
        XCTAssertEqual(decoded.clipboardThreshold, 20_000)
        XCTAssertEqual(decoded.killOnQuit, .neverKill)
    }

    @MainActor
    func testApplicationShutdownServicePolicies() {
        let bottle1 = Bottle(bottleUrl: URL(filePath: "/tmp/b1"), inFlight: false, isAvailable: true, cleanInvalidPins: false)
        let bottle2 = Bottle(bottleUrl: URL(filePath: "/tmp/b2"), inFlight: false, isAvailable: true, cleanInvalidPins: false)
        let bottle3 = Bottle(bottleUrl: URL(filePath: "/tmp/b3"), inFlight: false, isAvailable: true, cleanInvalidPins: false)

        bottle1.settings.killOnQuit = .inherit
        bottle2.settings.killOnQuit = .alwaysKill
        bottle3.settings.killOnQuit = .neverKill

        var terminated: [URL] = []
        let terminateMock: (Bottle) -> Void = { terminated.append($0.url) }

        // When globalKill is true: bottle1 (inherit) and bottle2 (always) terminate; bottle3 (never) is spared.
        ApplicationShutdownService.apply(
            to: [bottle1, bottle2, bottle3],
            globalKill: true,
            terminate: terminateMock,
            clearProcesses: { _ in },
            temporaryFiles: []
        )
        XCTAssertEqual(terminated, [bottle1.url, bottle2.url])

        terminated.removeAll()

        // When globalKill is false: only bottle2 (always) terminates; bottle1 and bottle3 are spared.
        ApplicationShutdownService.apply(
            to: [bottle1, bottle2, bottle3],
            globalKill: false,
            terminate: terminateMock,
            clearProcesses: { _ in },
            temporaryFiles: []
        )
        XCTAssertEqual(terminated, [bottle2.url])
    }
}
