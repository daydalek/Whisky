//
//  LaunchInteractionBroker.swift
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
import WhiskyBridgeProtocol
import WhiskyCore

/// Dialog decisions return to the helper with a one-use token bound to entry and clipboard version.
@MainActor
public final class LaunchInteractionBroker {
    private var pending: [String: (entryID: String, snapshot: ClipboardSnapshot)] = [:]
    public init() {}
    public func assess(
        entryID: String,
        clipboard: any ClipboardAccess,
        launcher: LauncherType?,
        policy: ClipboardPolicy,
        threshold: Int
    ) -> JSONValue? {
        let captured = CapturedClipboard(base: clipboard)
        let result = ClipboardPreflight.checkBeforeLaunch(
            clipboard: captured,
            launcher: launcher,
            policy: policy,
            threshold: threshold
        )
        guard case let .needsUserDecision(contentType, sizeBytes, preview) = result else { return nil }
        let token = UUID().uuidString
        pending = pending.filter { $0.value.entryID != entryID }
        if pending.count >= 64 {
            pending.removeAll()
        }
        pending[token] = (entryID, captured.observed)
        return .object(["accepted": .bool(false), "interaction": .object([
            "kind": .string("clipboard"), "token": .string(token), "contentType": .string(contentType),
            "sizeBytes": .integer(Int64(sizeBytes)), "preview": preview.map(JSONValue.string) ?? .null
        ])])
    }

    public func resolve(token: String, entryID: String, decision: String, clipboard: any ClipboardAccess) throws {
        guard decision == "clear" || decision == "keep" else { throw BridgeFailure(
            "invalid_params",
            "Unknown clipboard decision"
        ) }
        guard let prompt = pending[token], prompt.entryID == entryID,
              prompt.snapshot.version == clipboard.snapshot().version
        else {
            throw BridgeFailure(
                "stale_interaction",
                "Clipboard changed; request a fresh launch decision",
                retryable: true
            )
        }
        pending[token] = nil
        if decision == "clear", !clipboard.clear(ifMatches: prompt.snapshot) {
            throw BridgeFailure(
                "stale_interaction",
                "Clipboard changed before the decision was applied",
                retryable: true
            )
        }
    }
}

@MainActor
private final class CapturedClipboard: ClipboardAccess {
    let observed: ClipboardSnapshot
    let base: any ClipboardAccess
    init(base: any ClipboardAccess) {
        self.base = base
        observed = base.snapshot()
    }

    func snapshot() -> ClipboardSnapshot {
        observed
    }

    func clear(ifMatches snapshot: ClipboardSnapshot) -> Bool {
        base.clear(ifMatches: snapshot)
    }
}
