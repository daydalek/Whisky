//
//  PresentationPerformanceTests.swift
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

@Suite("Presentation performance correctness")
struct PresentationPerformanceTests {
    private func temporaryDirectory() throws -> URL {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test @MainActor func cachedPackingPreservesLayoutAcrossWidthsAndAspectChanges() {
        let cache = LibraryCoverGrid.Cache()
        for flags in [[false, true, false, true], [true, false, true, false], []] {
            for width in [464.0, 470, 900, 901, 300, 1] {
                let cached = cache.layout(width: width, landscape: flags)
                let fresh = LibraryCoverGrid(width: width, landscape: flags)
                #expect(cached.rows == fresh.rows)
                #expect(cached.spans == fresh.spans)
                #expect(cached.columnWidth == fresh.columnWidth)
            }
        }
    }

    @Test func logReaderPreservesUTF8AndPartialLinesAcrossBoundedReads() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("game.log")
        let text = "00af:fixme:test 日本語\r\nGame 中文\nError: failure\npartial"
        try Data(text.utf8).write(to: url)
        let reader = ConsoleLogReader(url: url)
        var complete: [ConsoleLogLine] = []
        var partial: ConsoleLogLine?
        var batch = try await reader.read(maxBytes: 1)
        while true {
            complete.append(contentsOf: batch.lines)
            partial = batch.partial
            if !batch.hasMore {
                break
            }
            batch = try await reader.read(maxBytes: 1)
        }
        #expect(try complete + [#require(partial)] == ConsoleLogReader.classify(text))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" 日本語\nnext".utf8))
        try handle.close()
        batch = try await reader.read()
        #expect(batch.lines.map(\.text) == ["partial 日本語"])
        #expect(batch.partial?.text == "next")
        #expect(!batch.reset)
    }

    @Test func logReaderRecoversFromTruncationAndAtomicReplacement() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("game.log")
        try Data("old line with length\n".utf8).write(to: url)
        let reader = ConsoleLogReader(url: url)
        _ = try await reader.read()
        try Data("new\n".utf8).write(to: url)
        let truncated = try await reader.read()
        #expect(truncated.reset)
        #expect(truncated.lines.map(\.text) == ["new"])
        try Data("atomic replacement\n".utf8).write(to: url, options: .atomic)
        let replaced = try await reader.read()
        #expect(replaced.reset)
        #expect(replaced.lines.map(\.text) == ["atomic replacement"])
    }

    @Test func prefixClassifierMatchesExistingPatterns() {
        let patterns = ["^[0-9a-f]{4}:", "^wine:", "^fixme:", "^err:", "^trace:", "^warn:"]
        for line in [
            "abc:",
            "abcd:",
            "ABCd:",
            "0123:",
            "0123X:",
            "warn:",
            "warning:",
            " err:",
            "wine:",
            "wines:",
            "日本語",
            "😀abc:",
            "0000:",
            "ffff:",
            "fffG:",
            "00000:"
        ] {
            let expected = patterns.contains { line.range(of: $0, options: .regularExpression) != nil }
            #expect((ConsoleLogReader.classify(line).first?.channel == .wineDebug) == expected)
        }
    }

    @Test func settingsWritesCoalesceAndExplicitWritesWin() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.plist")
        let writer = SettingsPersistence()
        for index in 0 ..< 100 {
            writer.enqueue(Data("\(index)".utf8), to: url)
        }
        writer.flush()
        #expect(try String(contentsOf: url, encoding: .utf8) == "99")
        var settings = ProgramSettings()
        settings.arguments = "queued"
        try settings.scheduleSave(to: url)
        settings.arguments = "explicit"
        try settings.encode(to: url)
        SettingsPersistence.shared.flush()
        #expect(try ProgramSettings.decode(from: url).arguments == "explicit")
    }

    @Test @MainActor func synchronousSettingsReadersObserveLatestQueuedEdits() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("drive_c"),
            withIntermediateDirectories: true
        )
        let bottle = Bottle(bottleUrl: root, isAvailable: true)
        bottle.settings.name = "Latest name"
        #expect(try BottleSettings.decode(from: root.appendingPathComponent("Metadata.plist")).name == "Latest name")
        let program = Program(url: root.appendingPathComponent("game.exe"), bottle: bottle, peFile: nil)
        program.settings.arguments = "latest arguments"
        #expect(try ProgramSettings.decode(from: program.settingsURL).arguments == "latest arguments")
    }

    @Test func newerExternalSettingsReplacementWins() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.plist")
        try Data("original".utf8).write(to: url)
        let writer = SettingsPersistence()
        writer.enqueue(Data("queued".utf8), to: url)
        try Data("external replacement".utf8).write(to: url, options: .atomic)
        writer.flush()
        #expect(try String(contentsOf: url, encoding: .utf8) == "external replacement")
        writer.enqueue(Data("later local edit".utf8), to: url)
        writer.flush()
        #expect(try String(contentsOf: url, encoding: .utf8) == "later local edit")
    }

    private actor QueryGate {
        private var continuation: CheckedContinuation<[WineProcess], Never>?
        var calls = 0
        func query() async -> [WineProcess] {
            calls += 1
            return await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            continuation?.resume(returning: [])
            continuation = nil
        }
    }

    @Test(.timeLimit(.minutes(1))) func sharedQueriesCoalesceAndNextObservationIsFresh() async throws {
        let pool = WineProcessSnapshotPool()
        let gate = QueryGate()
        let key = WineProcessSnapshotPool.Key(executable: URL(filePath: "/wine"), environment: ["WINEPREFIX": "/A"])
        let first = Task { try await pool.processes(key: key) { await gate.query() } }
        while await gate.calls == 0 {
            await Task.yield()
        }
        let second = Task { try await pool.processes(key: key) { await gate.query() } }
        while await pool.inFlightWaiters < 2 {
            await Task.yield()
        }
        #expect(await gate.calls == 1)
        await gate.release()
        _ = try await first.value
        _ = try await second.value
        let next = Task { try await pool.processes(key: key) { await gate.query() } }
        while await gate.calls < 2 {
            await Task.yield()
        }
        await gate.release()
        _ = try await next.value
        #expect(await gate.calls == 2)
    }

    @Test @MainActor func refreshedProgramsPreserveNewerEditorChanges() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = Bottle(bottleUrl: root, isAvailable: true)
        let url = root.appendingPathComponent("game.exe")
        let loaded = await Task.detached { Program.loadSettings(for: url, bottleURL: root) }.value
        let program = Program(url: url, bottle: bottle, peFile: nil, loadedSettings: loaded)
        let revision = program.settingsRevision
        let oldSnapshot = await Task.detached { Program.loadSettings(for: url, bottleURL: root) }.value
        program.settings.arguments = "new local edit"
        program.refreshLoadedSettings(oldSnapshot, expectedRevision: revision)
        #expect(program.settings.arguments == "new local edit")
        let currentRevision = program.settingsRevision
        var external = program.settings
        external.arguments = "external edit"
        try external.encode(to: program.settingsURL)
        let fresh = await Task.detached { Program.loadSettings(for: url, bottleURL: root) }.value
        program.refreshLoadedSettings(fresh, expectedRevision: currentRevision)
        #expect(program.settings.arguments == "external edit")
    }
}
