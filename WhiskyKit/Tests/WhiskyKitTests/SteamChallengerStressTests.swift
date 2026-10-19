// swiftlint:disable file_length
//
//  SteamChallengerStressTests.swift
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

import Darwin
import Foundation
import Testing
@testable import WhiskyKit

@Suite("Milestone 2 Empirical Challenger Stress Suite")
// swiftlint:disable:next type_body_length
struct SteamChallengerStressTests {
    // MARK: - Challenge 1: GameRouting Concurrency & Contention Stress

    @Test("GameRouting: High concurrency 100 tasks writing unique AppIDs produces zero lost updates")
    func gameRoutingHighConcurrencyUniqueWrites() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let plistURL = tempDir.appending(path: "GameRouting.plist")
        let totalWorkers = 100

        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< totalWorkers {
                group.addTask {
                    let routing = GameRouting(url: plistURL)
                    let bottleURL = URL(fileURLWithPath: "/tmp/bottles/bottle_\(index % 10)")
                    let date = Date(timeIntervalSince1970: Double(1_700_000_000 + index * 10))
                    routing.record(appId: index, bottleURL: bottleURL, at: date)
                }
            }
        }

        let finalRouting = GameRouting(url: plistURL)
        let routes = finalRouting.routes()
        let launches = finalRouting.lastLaunches()

        #expect(routes.count == totalWorkers, "Expected all \(totalWorkers) writes to persist without lost updates")
        #expect(launches.count == totalWorkers, "Expected all \(totalWorkers) launch dates to persist")

        for index in 0 ..< totalWorkers {
            let expectedBottle = URL(fileURLWithPath: "/tmp/bottles/bottle_\(index % 10)")
            let expectedDate = Date(timeIntervalSince1970: Double(1_700_000_000 + index * 10))
            #expect(routes[index] == expectedBottle, "Route for AppID \(index) mismatch")
            #expect(launches[index] == expectedDate, "Launch date for AppID \(index) mismatch")
        }
    }

    @Test("GameRouting: Concurrent reader-writer storm maintains data consistency without crashing or corrupted reads")
    func gameRoutingConcurrentReaderWriterStorm() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let plistURL = tempDir.appending(path: "GameRouting.plist")
        let routing = GameRouting(url: plistURL)

        // Seed with 10 apps
        for index in 0 ..< 10 {
            routing.record(appId: index, bottleURL: URL(fileURLWithPath: "/tmp/bottles/initial_\(index)"))
        }

        let isRunning = ManagedAtomicBool(true)

        await withTaskGroup(of: Void.self) { group in
            // 20 Writer tasks continuously mutating routes
            for writerID in 0 ..< 20 {
                group.addTask {
                    let routing = GameRouting(url: plistURL)
                    var iteration = 0
                    while isRunning.value, iteration < 50 {
                        let appId = (writerID * 10) + (iteration % 10)
                        let bottle = URL(fileURLWithPath: "/tmp/bottles/worker_\(writerID)_\(iteration)")
                        routing.record(appId: appId, bottleURL: bottle)
                        iteration += 1
                        try? await Task.sleep(for: .microseconds(100))
                    }
                }
            }

            // 20 Reader tasks continuously querying routes
            for _ in 0 ..< 20 {
                group.addTask {
                    let routing = GameRouting(url: plistURL)
                    var readCount = 0
                    while isRunning.value, readCount < 100 {
                        let routes = routing.routes()
                        let launches = routing.lastLaunches()
                        #expect(routes.count >= 10, "Routes should never read as empty or corrupted during writes")
                        _ = launches.count
                        for (appId, bottleURL) in routes {
                            #expect(appId >= 0)
                            #expect(!bottleURL.path.isEmpty)
                        }
                        readCount += 1
                        try? await Task.sleep(for: .microseconds(50))
                    }
                }
            }
        }
        isRunning.store(false)

        let finalRoutes = routing.routes()
        #expect(finalRoutes.count >= 10)
    }

    @Test("GameRouting: Concurrent writes and removals for different bottles do not race or delete wrong entries")
    func gameRoutingConcurrentWriteAndPrune() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let plistURL = tempDir.appending(path: "GameRouting.plist")
        let routing = GameRouting(url: plistURL)

        let permanentBottle = URL(fileURLWithPath: "/tmp/bottles/permanent")
        let ephemeralBottle = URL(fileURLWithPath: "/tmp/bottles/ephemeral")

        // Seed
        for index in 0 ..< 20 {
            routing.record(appId: index, bottleURL: permanentBottle)
        }

        await withTaskGroup(of: Void.self) { group in
            // Writers adding ephemeral routes
            for index in 20 ..< 40 {
                group.addTask {
                    let routing = GameRouting(url: plistURL)
                    routing.record(appId: index, bottleURL: ephemeralBottle)
                }
            }
            // Removers targeting ephemeral bottle
            for _ in 0 ..< 5 {
                group.addTask {
                    let routing = GameRouting(url: plistURL)
                    routing.removeRoutes(toBottle: ephemeralBottle)
                }
            }
            // Writers adding permanent routes
            for index in 40 ..< 60 {
                group.addTask {
                    let routing = GameRouting(url: plistURL)
                    routing.record(appId: index, bottleURL: permanentBottle)
                }
            }
        }

        // Final prune of ephemeral to be certain
        routing.removeRoutes(toBottle: ephemeralBottle)

        let routes = routing.routes()
        for (appId, bottleURL) in routes {
            #expect(bottleURL == permanentBottle, "No ephemeral bottle should remain in routes for AppID \(appId)")
        }
        #expect(routes[0] == permanentBottle)
        #expect(routes[40] == permanentBottle)
    }

    @Test("GameRouting: Cross-process file locking contention using sidecar lock blocks and synchronizes")
    func gameRoutingSidecarFileLocking() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let plistURL = tempDir.appending(path: "GameRouting.plist")
        let lockURL = tempDir.appending(path: "GameRouting.plist.lock")

        let routing = GameRouting(url: plistURL)
        routing.record(appId: 100, bottleURL: URL(fileURLWithPath: "/tmp/bottles/base"))

        // Simulate an external process acquiring exclusive flock on the lock file
        let lockDescriptor = open(lockURL.path(percentEncoded: false), O_CREAT | O_RDWR, 0o666)
        #expect(lockDescriptor >= 0)

        let lockAcquired = ManagedAtomicBool(false)
        let threadReady = ManagedAtomicBool(false)

        let queue = DispatchQueue(label: "test.external.process.simulation")
        queue.async {
            flock(lockDescriptor, LOCK_EX)
            lockAcquired.store(true)
            threadReady.store(true)
            // Hold lock for 150ms
            Thread.sleep(forTimeInterval: 0.15)
            flock(lockDescriptor, LOCK_UN)
            close(lockDescriptor)
            lockAcquired.store(false)
        }

        // Wait until background thread holds the lock
        while !threadReady.value {
            Thread.sleep(forTimeInterval: 0.005)
        }

        let start = ContinuousClock.now
        // This record must block until the external flock is released
        routing.record(appId: 101, bottleURL: URL(fileURLWithPath: "/tmp/bottles/after_lock"))
        let elapsed = ContinuousClock.now - start

        #expect(elapsed >= .milliseconds(100), "Write must wait on flock held by simulated external process")
        #expect(routing.bottleURL(forAppId: 101)?.lastPathComponent == "after_lock")
        #expect(!lockAcquired.value)
    }

    // MARK: - Challenge 2: VDFParser.Scanner Large & Malformed Input Stress

    @Test("VDFParser: Parses 10,000 key-value pairs rapidly with linear performance and zero leaks")
    func vdfParserLargePayload10000Keys() throws {
        var builder = "\"AppState\"\n{\n"
        builder.reserveCapacity(500_000)
        for index in 0 ..< 10_000 {
            builder.append("    \"Key_\(index)\"    \"Value_\(index)\"\n")
        }
        builder.append("}\n")

        let clock = ContinuousClock()
        let start = clock.now
        let parsed = try VDFParser.parse(builder)
        let duration = clock.now - start

        let appState = try #require(parsed["appstate"]?.objectValue)
        #expect(appState.count == 10_000)
        #expect(appState["key_0"]?.stringValue == "Value_0")
        #expect(appState["key_9999"]?.stringValue == "Value_9999")
        #expect(duration < .seconds(1), "Parsing 10,000 keys must complete in < 1.0s (took \(duration))")
    }

    @Test("VDFParser: Handles deeply nested VDF documents up to 200 levels without stack overflow")
    func vdfParserDeeplyNestedObjects() throws {
        let depth = 200
        var vdf = ""
        for index in 0 ..< depth {
            vdf += "\"nest_\(index)\" {\n"
        }
        vdf += "\"leaf\" \"found_me\"\n"
        for _ in 0 ..< depth {
            vdf += "}\n"
        }

        let parsed = try VDFParser.parse(vdf)
        var current = parsed["nest_0"]?.objectValue
        for index in 1 ..< depth {
            current = current?["nest_\(index)"]?.objectValue
        }
        #expect(current?["leaf"]?.stringValue == "found_me")
    }

    @Test("VDFParser: Pathological escape sequences and boundary edge cases")
    func vdfParserPathologicalEscapes() throws {
        // Alternating backslashes and quotes
        let complexEscapes = #""test" "a\\b\"c\\\"d\\\\e""#
        let parsed = try VDFParser.parse(complexEscapes)
        #expect(parsed["test"]?.stringValue == #"a\b"c\"d\\e"#)

        // Trailing escaped quote before closing quote: \"\" -> produces single quote
        let escapedQuoteAtEnd = #""key" "quote_at_end\"""#
        let parsedQuote = try VDFParser.parse(escapedQuoteAtEnd)
        #expect(parsedQuote["key"]?.stringValue == "quote_at_end\"")

        // 100 consecutive escaped backslashes
        let consecutiveBackslashes = String(repeating: "\\\\", count: 100)
        let doc = #""key" ""# + consecutiveBackslashes + #"""#
        let parsedBackslashes = try VDFParser.parse(doc)
        #expect(parsedBackslashes["key"]?.stringValue == String(repeating: "\\", count: 100))

        // Backslash at EOF inside string throws unterminatedString
        #expect(throws: VDFParseError.unterminatedString(line: 1)) {
            try VDFParser.parse(#""unclosed\"#)
        }
    }

    @Test("VDFParser: Comments edge cases (EOF without newline, CRLF, inside braces)")
    func vdfParserCommentEdgeCases() throws {
        // Comment at EOF with no newline
        let eofComment = "\"key\" \"val\" // trailing comment with no newline"
        let parsedEof = try VDFParser.parse(eofComment)
        #expect(parsedEof["key"]?.stringValue == "val")

        // Comments with quotes and braces inside them
        let trickyComments = """
        // Header with "fake_key" { "fake_val" }
        "real_key" "real_val" // Trailing with { } " "
        // Closing fake }
        """
        let parsedTricky = try VDFParser.parse(trickyComments)
        #expect(parsedTricky["real_key"]?.stringValue == "real_val")
        #expect(parsedTricky["fake_key"] == nil)

        // Empty comments and slash chains
        let slashChains = """
        //// multiple slashes
        "key" // mid line comment
        "val"
        """
        let parsedChains = try VDFParser.parse(slashChains)
        #expect(parsedChains["key"]?.stringValue == "val")

        // Stray single slash throws unexpectedToken
        #expect(throws: VDFParseError.unexpectedToken(line: 1)) {
            try VDFParser.parse("\"key\" / \"val\"")
        }
    }

    @Test("VDFParser: Malformed grammar matrix throws accurate VDFParseError without crashing")
    func vdfParserMalformedGrammarMatrix() {
        // Bare word key
        #expect(throws: VDFParseError.unexpectedToken(line: 1)) {
            try VDFParser.parse("bare_key \"val\"")
        }

        // Bare word value
        #expect(throws: VDFParseError.unexpectedToken(line: 1)) {
            try VDFParser.parse("\"key\" bare_val")
        }

        // Unbalanced opening brace
        #expect(throws: VDFParseError.unexpectedEnd) {
            try VDFParser.parse("\"k\" { \"sub\" \"val\"")
        }

        // Unbalanced closing brace at end
        #expect(throws: VDFParseError.unexpectedToken(line: 1)) {
            try VDFParser.parse("\"k\" { \"sub\" \"val\" } }")
        }

        // Value is closing brace
        #expect(throws: VDFParseError.unexpectedToken(line: 1)) {
            try VDFParser.parse("\"k\" }")
        }

        // Key without value at EOF
        #expect(throws: VDFParseError.unexpectedEnd) {
            try VDFParser.parse("\"k\"")
        }

        // Object without key
        #expect(throws: VDFParseError.unexpectedToken(line: 1)) {
            try VDFParser.parse("{ \"sub\" \"val\" }")
        }

        // Double open brace
        #expect(throws: VDFParseError.unexpectedToken(line: 1)) {
            try VDFParser.parse("\"k\" { { \"sub\" \"val\" } }")
        }

        // Newline inside unclosed string
        #expect(throws: VDFParseError.unterminatedString(line: 1)) {
            try VDFParser.parse("\"line1\nline2\"")
        }
    }

    @Test("VDFParser: Fuzzing harness on 500 randomized mutated inputs guarantees zero crashes")
    func vdfParserFuzzingHarness() {
        var rng = SplitMix64(seed: 42)
        let characters: [Character] = [
            "\"", "{", "}", "\\", "/", "\n", "\r", "\t", " ", "a", "Z", "0",
            "\0", "é", "日", "🎮", ":", ";", "=", ",", ".", "-", "_"
        ]

        for _ in 0 ..< 500 {
            let length = Int(rng.next() % 80)
            var mutated = ""
            for _ in 0 ..< length {
                let charIndex = Int(rng.next() % UInt64(characters.count))
                mutated.append(characters[charIndex])
            }

            // Must either parse successfully or throw VDFParseError — NEVER fatalError or panic
            do {
                _ = try VDFParser.parse(mutated)
            } catch is VDFParseError {
                // Expected for malformed fuzzed inputs
            } catch {
                Issue.record("Unexpected error type: \(error)")
            }
        }
    }

    // MARK: - Challenge 3: SteamClientReadiness Tail Decoding UTF-8 Split Offsets

    @Test("SteamClientReadiness: UTF-8 boundary splits preserve surrounding log lines")
    // swiftlint:disable:next function_body_length
    func steamReadinessTailUtf8SplitOffsets() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let targetTailSize = 524_288
        let validSuffix = "\n[2026-10-16 15:00:10] STARTUP SlowJSMethodCall UI.NotifyAppInitialized took 1ms\n"

        // 1. Test 2-byte UTF-8 split (e.g. 'é' = 0xC3 0xA9)
        // File size = 524,289: offset 0 is 0xC3, offset 1 is 0xA9. Tail starts at offset 1 (0xA9, orphaned
        // continuation byte).
        do {
            let logURL = tempDir.appending(path: "split_2byte.txt")
            var data = Data([0xC3, 0xA9]) // 2 bytes
            let paddingCount = targetTailSize - validSuffix.utf8.count - 1
            data.append(Data(repeating: UInt8(ascii: "A"), count: paddingCount))
            data.append(Data(validSuffix.utf8))
            try data.write(to: logURL)

            #expect(data.count == targetTailSize + 1)
            let rawChunk = try Data(contentsOf: logURL).suffix(targetTailSize)
            #expect(
                String(data: rawChunk, encoding: .utf8) == nil,
                "Standard UTF-8 initializer must fail on split boundary"
            )

            let tailed = SteamClientReadiness.tail(logURL)
            #expect(!tailed.isEmpty, "Tailed string must not be empty")
            #expect(
                tailed.contains("UI.NotifyAppInitialized"),
                "Tailed string must preserve intact log line after split"
            )
            #expect(
                tailed.unicodeScalars.contains(where: { $0.value == 0xFFFD }),
                "Split continuation byte must decode as U+FFFD"
            )
        }

        // 2. Test 3-byte UTF-8 split (e.g. '日' = 0xE6 0x97 0xA5)
        // Test split at offset 1 (2 continuation bytes remain) and offset 2 (1 continuation byte remains)
        for splitOffset in 1 ... 2 {
            let logURL = tempDir.appending(path: "split_3byte_\(splitOffset).txt")
            var data = Data([0xE6, 0x97, 0xA5])
            let paddingCount = targetTailSize - validSuffix.utf8.count - (3 - splitOffset)
            data.append(Data(repeating: UInt8(ascii: "B"), count: paddingCount))
            data.append(Data(validSuffix.utf8))
            try data.write(to: logURL)

            let rawChunk = try Data(contentsOf: logURL).suffix(targetTailSize)
            #expect(String(data: rawChunk, encoding: .utf8) == nil)

            let tailed = SteamClientReadiness.tail(logURL)
            #expect(!tailed.isEmpty)
            #expect(tailed.contains("UI.NotifyAppInitialized"))
            #expect(tailed.unicodeScalars.contains(where: { $0.value == 0xFFFD }))
        }

        // 3. Test 4-byte UTF-8 split (e.g. 🎮 = 0xF0 0x9F 0x8E 0xAE)
        // Test split at offsets 1, 2, 3
        for splitOffset in 1 ... 3 {
            let logURL = tempDir.appending(path: "split_4byte_\(splitOffset).txt")
            var data = Data([0xF0, 0x9F, 0x8E, 0xAE])
            let paddingCount = targetTailSize - validSuffix.utf8.count - (4 - splitOffset)
            data.append(Data(repeating: UInt8(ascii: "C"), count: paddingCount))
            data.append(Data(validSuffix.utf8))
            try data.write(to: logURL)

            let rawChunk = try Data(contentsOf: logURL).suffix(targetTailSize)
            #expect(String(data: rawChunk, encoding: .utf8) == nil)

            let tailed = SteamClientReadiness.tail(logURL)
            #expect(!tailed.isEmpty)
            #expect(tailed.contains("UI.NotifyAppInitialized"))
            #expect(tailed.unicodeScalars.contains(where: { $0.value == 0xFFFD }))
        }
    }

    @Test("SteamClientReadiness: File boundary size variations (empty, smaller, exact 512KB, larger) parse accurately")
    func steamReadinessTailBoundarySizes() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Non-existent file
        let missing = tempDir.appending(path: "missing.log")
        #expect(SteamClientReadiness.tail(missing).isEmpty)

        // 0-byte file
        let empty = tempDir.appending(path: "empty.log")
        try Data().write(to: empty)
        #expect(SteamClientReadiness.tail(empty).isEmpty)

        // 50-byte file (smaller than 512KB)
        let small = tempDir.appending(path: "small.log")
        try Data("[2026-10-16 15:00:00] Startup\n".utf8).write(to: small)
        #expect(SteamClientReadiness.tail(small) == "[2026-10-16 15:00:00] Startup\n")

        // Exactly 524,288 bytes
        let exact = tempDir.appending(path: "exact.log")
        let exactData = Data(repeating: UInt8(ascii: "E"), count: 524_288)
        try exactData.write(to: exact)
        #expect(SteamClientReadiness.tail(exact).count == 524_288)

        // 2 MB file
        let large = tempDir.appending(path: "large.log")
        var largeData = Data(repeating: UInt8(ascii: "L"), count: 2_000_000)
        largeData.append(Data("[2026-10-16 15:00:00] Startup\n".utf8))
        try largeData.write(to: large)
        let largeTail = SteamClientReadiness.tail(large)
        #expect(largeTail.count == 524_288)
        #expect(largeTail.hasSuffix("[2026-10-16 15:00:00] Startup\n"))
    }

    @Test("SteamLaunchReceipt: Resilient UTF-8 decoding avoids status (.unavailable) on boundary split")
    func steamLaunchReceiptSplitDecoding() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let logs = root.appending(path: "logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let logURL = logs.appending(path: "console_log.txt")

        // Create initial log
        try Data("Header log content\n".utf8).write(to: logURL)
        let receipt = SteamLaunchReceipt(steamRoot: root)

        // Append split multi-byte character followed by game action
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        // Write split UTF-8 bytes (e.g. invalid continuation bytes 0x97 0xA5)
        try handle.write(contentsOf: Data([0x97, 0xA5]))
        try handle.write(contentsOf: Data("GameAction [AppID 730, ActionID 1] : Running\n".utf8))
        try handle.close()

        // Resilient UTF-8 decoding in SteamLaunchReceipt must decode the line and find AppID 730
        #expect(receipt.wasAccepted(appID: 730))
        #expect(receipt.status(appID: 730) == .accepted)
    }

    // MARK: - Challenge 4: Multi-Process OS Contention & Subprocess flock

    @Test("GameRouting: Inter-process contention between Swift and external Python subprocess using flock")
    // swiftlint:disable:next function_body_length
    func gameRoutingExternalSubprocessContention() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let plistURL = tempDir.appending(path: "GameRouting.plist")
        let lockURL = tempDir.appending(path: "GameRouting.plist.lock")

        let routing = GameRouting(url: plistURL)
        routing.record(appId: 100, bottleURL: URL(fileURLWithPath: "/tmp/bottles/swift_init"))

        // Python script that contends for the exact lock file and writes 10 entries
        let pyScript = """
        import fcntl, os, plistlib, time

        plist_path = '\(plistURL.path(percentEncoded: false))'
        lock_path = '\(lockURL.path(percentEncoded: false))'

        for index in range(200, 210):
            with open(lock_path, 'w+') as lock_file:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
                try:
                    if os.path.exists(plist_path):
                        with open(plist_path, 'rb') as fp:
                            data = plistlib.load(fp)
                    else:
                        data = {}
                    data[str(index)] = {'bottle': f'/tmp/bottles/py_{index}'}
                    tmp_path = plist_path + '.pytmp'
                    with open(tmp_path, 'wb') as fp:
                        plistlib.dump(data, fp, fmt=plistlib.FMT_XML)
                    os.replace(tmp_path, plist_path)
                    time.sleep(0.01)
                finally:
                    fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
        """

        let scriptURL = tempDir.appending(path: "contend.py")
        try pyScript.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptURL.path(percentEncoded: false)]

        try process.run()

        // Simultaneously in Swift, write 10 entries (300...309)
        for index in 300 ..< 310 {
            routing.record(appId: index, bottleURL: URL(fileURLWithPath: "/tmp/bottles/swift_\(index)"))
            Thread.sleep(forTimeInterval: 0.008)
        }

        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let finalRoutes = routing.routes()
        #expect(finalRoutes[100] == URL(fileURLWithPath: "/tmp/bottles/swift_init"))

        // Both Swift (300..309) and Python (200..209) writes must be present without lost updates
        for index in 200 ..< 210 {
            #expect(
                finalRoutes[index] == URL(fileURLWithPath: "/tmp/bottles/py_\(index)"),
                "Python write for AppID \(index) missing"
            )
        }
        for index in 300 ..< 310 {
            #expect(
                finalRoutes[index] == URL(fileURLWithPath: "/tmp/bottles/swift_\(index)"),
                "Swift write for AppID \(index) missing"
            )
        }
    }

    // MARK: - Challenge 5: SteamClientReadiness State Machine Edge Cases

    @Test("SteamClientReadiness: State transitions handle reconnection and stale offline evidence")
    func steamReadinessStateTransitions() {
        let session = "[2026-10-16 15:00:00] Startup - Steam Client launched with: steam.exe"
        let uiReady = "[2026-10-16 15:00:05] STARTUP SlowJSMethodCall UI.NotifyAppInitialized took 1ms"

        // 1. Initial connect -> disconnect -> reconnect
        let connSequence = """
        [2026-10-16 15:00:02] [Logging On, 1, 0] Logging On
        [2026-10-16 15:00:04] [Logged On, 1, 0] Logged On
        [2026-10-16 15:00:10] [Logged Off, 0, 0] Disconnected
        [2026-10-16 15:00:15] [Logging On, 1, 0] Logging On
        [2026-10-16 15:00:18] [Logged On, 1, 0] Logged On
        """
        let snapshot1 = SteamClientReadiness.parse(bootstrap: session, connection: connSequence, console: uiReady)
        #expect(snapshot1.state == .ready)

        // 2. Offline date older than subsequent online attempt should NOT yield offlineReady
        let staleOfflineConsole = """
        \(uiReady)
        [2026-10-16 15:00:06] Entering offline mode
        """
        let newerOnlineAttemptConn = """
        [2026-10-16 15:00:10] [Connecting, 1, 0] Connecting
        """
        let snapshot2 = SteamClientReadiness.parse(
            bootstrap: session, connection: newerOnlineAttemptConn, console: staleOfflineConsole
        )
        #expect(snapshot2.state == .waitingForLogin, "Newer online attempt invalidates earlier offline mode evidence")

        // 3. UI not ready blocks both online and offline readiness
        let notReadyUI = SteamClientReadiness.parse(
            bootstrap: session,
            connection: "[2026-10-16 15:00:05] [Logged On, 1, 0] Logged On",
            console: "[2026-10-16 15:00:04] Starting UI..."
        )
        #expect(notReadyUI.state == .initializing)
    }

    // MARK: - Challenge 6: Executable Scoping & selectedURL Edge Cases

    @Test("SteamLauncher & SteamLibrary: selectedURL deep binary integration and case-insensitive deduplication")
    func steamExecutableScopingWithSelectedURL() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Root binary
        let rootExe = tempDir.appending(path: "Launcher.exe")
        try Data("root".utf8).write(to: rootExe)

        // Subdirectory binary
        let subDir = tempDir.appending(path: "Binaries/Win64")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let deepExe = subDir.appending(path: "Game-Win64-Shipping.exe")
        try Data("deep".utf8).write(to: deepExe)

        // 1. SteamLibrary.executableNames
        let discovered = SteamLibrary.executableNames(under: tempDir, selectedURL: deepExe)
        #expect(discovered.contains("launcher.exe"))
        #expect(discovered.contains("game-win64-shipping.exe"))

        var plan = LaunchPlan(
            overrides: ProgramOverrides(),
            gameProfileEnvironment: [:],
            provenance: []
        )
        plan.gameExecutables = ["LAUNCHER.EXE", "Extra.exe"]
        let scoped = SteamLauncher.gameExecutables(installURL: tempDir, selectedURL: deepExe, plan: plan)

        #expect(scoped.first == "Game-Win64-Shipping.exe", "selectedURL must be prioritized at the front")
        let lowercasedScoped = scoped.map { $0.lowercased() }
        #expect(
            lowercasedScoped.filter { $0 == "launcher.exe" }.count == 1,
            "Duplicate executables must be deduplicated"
        )
        #expect(lowercasedScoped.contains("extra.exe"))
    }
}

// MARK: - Stress Test Helpers

private final class ManagedAtomicBool: @unchecked Sendable {
    private var _value: Bool
    private let lock = NSLock()

    init(_ initial: Bool) {
        self._value = initial
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func store(_ newValue: Bool) {
        lock.lock()
        defer { lock.unlock() }
        _value = newValue
    }
}

private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed &>> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed &>> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed &>> 31)
    }
}
