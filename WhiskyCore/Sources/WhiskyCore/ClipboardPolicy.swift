//
//  ClipboardPolicy.swift
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

/// Per-bottle clipboard handling policy.
///
/// Controls how the clipboard is checked and managed before launching Wine programs.
/// Each bottle can specify its own policy, or use the default `auto` behavior.
public enum ClipboardPolicy: String, Codable, CaseIterable, Sendable {
    /// Auto-clear for known multiplayer launchers, warn for others (default)
    case auto
    /// Always show a warning when clipboard content is large
    case alwaysWarn = "warn"
    /// Always clear the clipboard before launching
    case alwaysClear = "clear"
    /// Never warn or clear the clipboard
    case never
}

/// Result of a clipboard check before launching a Wine program.
///
/// The app layer uses this to decide whether to show a toast, alert, or proceed silently.
public enum ClipboardCheckResult: Equatable, Sendable {
    /// Content is small or empty, no action needed
    case safe
    /// Content was auto-cleared (for known multiplayer launchers or always-clear policy)
    case autoCleared(contentType: String, sizeBytes: Int)
    /// Content is large and needs user decision (show alert/sheet in app layer)
    case needsUserDecision(contentType: String, sizeBytes: Int, textPreview: String?)
}
