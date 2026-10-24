//
//  ClipboardPreflightTests.swift
//  WhiskyCore
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
@testable import WhiskyCore

@MainActor
final class MemoryClipboard: ClipboardAccess {
    var content: ClipboardSnapshot
    var reads = 0
    var clears = 0
    init(_ content: ClipboardSnapshot) {
        self.content = content
    }

    func snapshot() -> ClipboardSnapshot {
        reads += 1
        return content
    }

    func clear(ifMatches snapshot: ClipboardSnapshot) -> Bool {
        guard let version = snapshot.version, version == content.version else { return false }
        clears += 1
        content = ClipboardSnapshot(kind: .empty, sizeBytes: 0, version: "cleared")
        return true
    }
}

@Suite("Portable clipboard preflight")
@MainActor
struct ClipboardPreflightTests {
    private func clipboard(size: Int = 20_000) -> MemoryClipboard {
        MemoryClipboard(ClipboardSnapshot(kind: .text, sizeBytes: size, textPreview: "preview", version: "1"))
    }

    @Test func disabledPolicySkipsReadingAndThresholdBoundaryPreservesContent() {
        let board = clipboard()
        #expect(ClipboardPreflight.checkBeforeLaunch(clipboard: board, policy: .never) == .safe)
        #expect(board.reads == 0)
        let boundary = clipboard(size: ClipboardPreflight.largeContentThreshold)
        #expect(ClipboardPreflight.checkBeforeLaunch(clipboard: boundary, policy: .alwaysClear) == .safe)
        #expect(boundary.clears == 0)
    }

    @Test(arguments: LauncherType.allCases) func autoPolicyUsesSharedLauncherTraits(_ launcher: LauncherType) {
        let board = clipboard()
        let result = ClipboardPreflight.checkBeforeLaunch(clipboard: board, launcher: launcher, policy: .auto)
        if [.steam, .epicGames, .battleNet].contains(launcher) {
            #expect(result == .autoCleared(contentType: "text", sizeBytes: 20_000))
            #expect(board.clears == 1)
        } else {
            #expect(result == .needsUserDecision(contentType: "text", sizeBytes: 20_000, textPreview: "preview"))
            #expect(board.clears == 0)
        }
    }

    @Test func warningPolicyRespectsKeepEvenForMultiplayerLaunchers() {
        let board = clipboard()
        var prompts = 0
        let result = ClipboardPreflight.checkWithBlockingPrompt(
            clipboard: board, launcher: .steam, policy: .alwaysWarn
        ) { _ in prompts += 1
            return .keep
        }
        #expect(result == .safe)
        #expect(prompts == 1)
        #expect(board.clears == 0)
    }

    @Test func asynchronousPromptProtectsReplacedClipboardContent() async {
        let board = clipboard()
        let result = await ClipboardPreflight.checkWithPrompt(clipboard: board, policy: .alwaysWarn) { _ in
            board.content = ClipboardSnapshot(kind: .text, sizeBytes: 30_000, version: "2")
            return .clear
        }
        #expect(result == .safe)
        #expect(board.content.version == "2")
        #expect(board.clears == 0)
    }

    @Test func clearAndCancellationReportOnlyCompletedOperations() async {
        let board = clipboard()
        let result = await ClipboardPreflight.checkWithPrompt(clipboard: board, policy: .alwaysWarn) { _ in .clear }
        #expect(result == .autoCleared(contentType: "text", sizeBytes: 20_000))
        #expect(board.clears == 1)
        let cancelled = clipboard()
        let task = Task {
            await ClipboardPreflight.checkWithPrompt(clipboard: cancelled, policy: .alwaysWarn) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return .clear
            }
        }
        #expect(await task.value == .safe)
        #expect(cancelled.clears == 0)
    }

    @Test func previewBoundsUseCharactersAndUnknownVersionsPreserveContent() {
        let text = String(repeating: "图🙂", count: 40)
        let snapshot = ClipboardSnapshot(kind: .text, sizeBytes: text.utf8.count, textPreview: text)
        #expect(snapshot.textPreview?.count == 50)
        #expect(snapshot.sizeBytes == 280)
        let board = MemoryClipboard(snapshot)
        #expect(ClipboardPreflight.checkBeforeLaunch(clipboard: board, policy: .alwaysClear, threshold: 0) == .safe)
        #expect(board.clears == 0)
    }
}
