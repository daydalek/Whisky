//
//  WinetricksExecutionTests.swift
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
import Testing
@testable import WhiskyKit

@Test func winetricksOutputPreservesFragmentedUnicodeAndBoundsLines() {
    let decoder = WinetricksOutputDecoder()
    var lines: [String] = []
    for byte in Data("中文 日本語\n尾部".utf8) {
        lines += decoder.append(Data([byte]))
    }
    lines += decoder.append(Data(), finish: true)
    #expect(lines == ["中文 日本語", "尾部"])
    #expect(decoder.append(Data(repeating: 65, count: 20_000)).joined().count == 20_000)
}

@Test func winetricksWaitTerminatesTimedOutAndCancelledCommands() async throws {
    for cancel in [false, true] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        let task = Task { await WinetricksService.awaitProcessCompletion(process, timeout: cancel ? 60 : 0.05) }
        if cancel {
            task.cancel()
        }
        let failure = await task.value
        #expect(failure == (cancel ? "Installation cancelled" : "Installation timed out"))
        #expect(!process.isRunning)
    }
}
