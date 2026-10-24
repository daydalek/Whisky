//
//  WorkspaceStyle.swift
//  WhiskyCrossUI
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

import SwiftCrossUI

enum WhiskyStyle {
    static let background = Color.adaptive(light: Color(white: 0.97), dark: Color(white: 0.10))
    static let sidebar = Color.adaptive(light: Color(white: 0.94), dark: Color(white: 0.13))
    static let surface = Color.adaptive(light: .white, dark: Color(white: 0.17))
    static let selection = Color.adaptive(light: Color(white: 0.86), dark: Color(white: 0.25))
    static let secondary = Color.adaptive(light: Color(white: 0.44), dark: Color(white: 0.65))
    static let primary = Color.adaptive(light: Color(white: 0.10), dark: Color(white: 0.92))
    static let accent = Color(red: 1, green: 0.49, blue: 0.06)
}

/// Plain toolkit buttons keep their label above the AppKit native background.
/// The shared surface defines the same readable control on Gtk and AppKit.
struct WhiskyAction: View {
    let title: String
    var prominent = false
    var selected = false
    var action: @MainActor @Sendable () -> Void

    init(
        _ title: String,
        prominent: Bool = false,
        selected: Bool = false,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        self.title = title
        self.prominent = prominent
        self.selected = selected
        self.action = action
    }

    var body: some View {
        WorkspaceButton(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: prominent ? .semibold : .regular))
            .foregroundColor(prominent ? .white : WhiskyStyle.primary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(prominent ? WhiskyStyle.accent : selected ? WhiskyStyle.selection : WhiskyStyle.surface)
            .cornerRadius(8)
    }
}

struct WhiskyBadge: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundColor(WhiskyStyle.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(WhiskyStyle.selection.opacity(0.45)).cornerRadius(12)
    }
}
