//
//  MacOSProgramInteraction.swift
//  Whisky
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

import AppKit
import WhiskyCore

@MainActor
public struct MacOSProgramInteraction: ProgramUserInteraction {
    public static let shared = MacOSProgramInteraction()
    public init() {}
    public var launchMode: LibraryLaunchRequest.Mode {
        NSEvent.modifierFlags.contains(.shift) ? .terminal : .standard
    }

    public func showLaunchFailure(programName: String, message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "alert.message")
        alert.informativeText = String(localized: "alert.info") + " \(programName): " + message
        alert.alertStyle = .critical
        alert.addButton(withTitle: String(localized: "button.ok"))
        alert.runModal()
    }

    public func decideClipboard(_ snapshot: ClipboardSnapshot) -> ClipboardDecision {
        let contentType = snapshot.kind.rawValue
        let sizeBytes = snapshot.sizeBytes
        let textPreview = snapshot.textPreview
        let alert = NSAlert()
        alert.messageText = String(localized: "clipboard.large.title")

        let sizeKB = String(format: "%.1f", Double(sizeBytes) / 1_024.0)
        let message: String
        switch contentType {
        case "text":
            let preview = textPreview ?? ""
            message = String(localized: "clipboard.large.message.text")
                .replacingOccurrences(of: "{size}", with: sizeKB)
                .replacingOccurrences(of: "{preview}", with: preview)
        case "image":
            message = String(localized: "clipboard.large.message.image")
                .replacingOccurrences(of: "{size}", with: sizeKB)
        default:
            message = String(localized: "clipboard.large.message.other")
                .replacingOccurrences(of: "{size}", with: sizeKB)
        }

        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "clipboard.clear"))
        alert.addButton(withTitle: String(localized: "clipboard.keep"))

        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .clear : .keep
    }
}
