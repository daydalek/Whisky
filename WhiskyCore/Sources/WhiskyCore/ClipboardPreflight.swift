//
//  ClipboardPreflight.swift
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

public struct ClipboardSnapshot: Equatable, Sendable {
    public enum Kind: String, Sendable { case empty, text, image, other }
    public let kind: Kind
    public let sizeBytes: Int
    public let textPreview: String?
    public let version: String?

    public init(kind: Kind, sizeBytes: Int, textPreview: String? = nil, version: String? = nil) {
        self.kind = kind
        self.sizeBytes = max(0, sizeBytes)
        self.textPreview = textPreview.map { String($0.prefix(50)) }
        self.version = version
    }
}

public enum ClipboardDecision: Sendable { case clear, keep }

@MainActor
public protocol ClipboardAccess: AnyObject {
    func snapshot() -> ClipboardSnapshot
    /// Clears the observed content when its version still matches.
    func clear(ifMatches snapshot: ClipboardSnapshot) -> Bool
}

public enum ClipboardPreflight {
    public static let largeContentThreshold = 10 * 1_024

    @MainActor
    public static func checkBeforeLaunch(
        clipboard: any ClipboardAccess, launcher: LauncherType? = nil, policy: ClipboardPolicy,
        threshold: Int = largeContentThreshold
    ) -> ClipboardCheckResult {
        inspect(clipboard: clipboard, launcher: launcher, policy: policy, threshold: threshold).result
    }

    @MainActor
    public static func checkWithBlockingPrompt(
        clipboard: any ClipboardAccess, launcher: LauncherType? = nil, policy: ClipboardPolicy,
        threshold: Int = largeContentThreshold, decide: (ClipboardSnapshot) -> ClipboardDecision
    ) -> ClipboardCheckResult {
        let assessment = inspect(clipboard: clipboard, launcher: launcher, policy: policy, threshold: threshold)
        guard case .needsUserDecision = assessment.result, let snapshot = assessment.snapshot else {
            return assessment.result
        }
        return finalize(snapshot: snapshot, decision: decide(snapshot), clipboard: clipboard)
    }

    @MainActor
    public static func checkWithPrompt(
        clipboard: any ClipboardAccess, launcher: LauncherType? = nil, policy: ClipboardPolicy,
        threshold: Int = largeContentThreshold, decide: (ClipboardSnapshot) async -> ClipboardDecision
    ) async -> ClipboardCheckResult {
        let assessment = inspect(clipboard: clipboard, launcher: launcher, policy: policy, threshold: threshold)
        guard case .needsUserDecision = assessment.result, let snapshot = assessment.snapshot else {
            return assessment.result
        }
        let decision = await decide(snapshot)
        guard !Task.isCancelled else { return .safe }
        return finalize(snapshot: snapshot, decision: decision, clipboard: clipboard)
    }

    @MainActor
    private static func inspect(
        clipboard: any ClipboardAccess, launcher: LauncherType?, policy: ClipboardPolicy, threshold: Int
    ) -> (snapshot: ClipboardSnapshot?, result: ClipboardCheckResult) {
        guard policy != .never else { return (nil, .safe) }
        let snapshot = clipboard.snapshot()
        guard snapshot.sizeBytes > max(0, threshold) else { return (snapshot, .safe) }
        if policy == .alwaysClear || (policy == .auto && launcher?.usesClipboard == true) {
            return (snapshot, finalize(snapshot: snapshot, decision: .clear, clipboard: clipboard))
        }
        return (snapshot, .needsUserDecision(
            contentType: snapshot.kind.rawValue,
            sizeBytes: snapshot.sizeBytes,
            textPreview: snapshot.textPreview
        ))
    }

    @MainActor
    private static func finalize(
        snapshot: ClipboardSnapshot, decision: ClipboardDecision, clipboard: any ClipboardAccess
    ) -> ClipboardCheckResult {
        guard case .clear = decision, clipboard.clear(ifMatches: snapshot) else { return .safe }
        return .autoCleared(contentType: snapshot.kind.rawValue, sizeBytes: snapshot.sizeBytes)
    }
}
