//
//  WorkspaceButton.swift
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

/// A text action uses the native accessible control on each supported desktop.
struct WorkspaceButton: View {
    let title: String
    let action: @MainActor @Sendable () -> Void

    init(_ title: String, action: @escaping @MainActor @Sendable () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        #if os(macOS)
        MacOSWorkspaceButton(title: title, action: action)
        #else
        Button(title, action: action).buttonStyle(.plain)
        #endif
    }

    // The spelling is the SwiftCrossUI View protocol requirement.
    // swiftlint:disable:next identifier_name
    var _asMenuItems: [MenuItem] {
        Button(title, action: action)._asMenuItems
    }
}
