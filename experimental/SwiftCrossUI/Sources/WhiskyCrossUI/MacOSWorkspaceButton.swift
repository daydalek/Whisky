//
//  MacOSWorkspaceButton.swift
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

#if os(macOS)
import AppKit
@_spi(Backends) import SwiftCrossUI

/// AppKit's standard NSButton provides labels, keyboard focus and AXPress.
/// This adapter avoids the pinned backend's inaccessible custom label wrapper.
struct MacOSWorkspaceButton: View {
    let title: String
    let action: @MainActor @Sendable () -> Void
    // The explicit return bypasses ViewBuilder for this primitive leaf.
    // swiftformat:disable redundantReturn
    var body: Never {
        return fatalError("A native button is a leaf view")
    }

    // swiftformat:enable redundantReturn

    func children(
        backend: some BaseAppBackend,
        snapshots: [ViewGraphSnapshotter.NodeSnapshot]?,
        environment: EnvironmentValues
    ) -> any ViewGraphNodeChildren {
        EmptyViewChildren()
    }

    func layoutableChildren(backend: some BaseAppBackend, children: any ViewGraphNodeChildren)
        -> [LayoutSystem.LayoutableChild] {
        []
    }

    func asWidget<Backend: BaseAppBackend>(_ children: any ViewGraphNodeChildren, backend: Backend) -> Backend.Widget {
        let button = ActionButton()
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.target = button
        button.action = #selector(ActionButton.invoke)
        guard let widget = button as? Backend.Widget else { fatalError("AppKit button requires AppKitBackend") }
        return widget
    }

    func computeLayout<Backend: BaseAppBackend>(
        _ widget: Backend.Widget,
        children: any ViewGraphNodeChildren,
        proposedSize: ProposedViewSize,
        environment: EnvironmentValues,
        backend: Backend
    ) -> ViewLayoutResult {
        guard let button = widget as? ActionButton else { preconditionFailure("AppKit button widget mismatch") }
        button.command = action
        button.isEnabled = environment.isEnabled
        let font = environment.resolvedFont
        let weight: NSFont.Weight = font.weight == .bold ? .bold : font.weight == .semibold ? .semibold : .regular
        let nativeFont = NSFont.systemFont(ofSize: font.pointSize, weight: weight)
        let color = environment.suggestedForegroundColor.resolve(in: environment)
        let attributed = NSAttributedString(string: title, attributes: [
            .font: nativeFont,
            .foregroundColor: NSColor(
                srgbRed: CGFloat(color.red),
                green: CGFloat(color.green),
                blue: CGFloat(color.blue),
                alpha: CGFloat(color.opacity)
            )
        ])
        button.attributedTitle = attributed
        button.setAccessibilityLabel(title)
        button.cell?.lineBreakMode = .byTruncatingTail
        let measured = attributed.size()
        let width = min(measured.width.rounded(.up) + 4, proposedSize.width ?? .infinity)
        return .leafView(size: ViewSize(max(1, width), max(20, measured.height.rounded(.up) + 2)))
            .with(\.isNeverFocusable, false)
    }

    func commit<Backend: BaseAppBackend>(
        _ widget: Backend.Widget,
        children: any ViewGraphNodeChildren,
        layout: ViewLayoutResult,
        environment: EnvironmentValues,
        backend: Backend
    ) {
        backend.setSize(of: widget, to: layout.size.vector)
    }

    final class ActionButton: NSButton {
        var command: (@MainActor @Sendable () -> Void)?
        @objc func invoke() {
            if isEnabled {
                command?()
            }
        }
    }
}
#endif
