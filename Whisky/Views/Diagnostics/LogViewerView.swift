//
//  LogViewerView.swift
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
import SwiftUI
import WhiskyKit

/// Filter modes for the log viewer.
enum LogFilterMode: Equatable, Sendable {
    case all
    case tagged
    case crashRelated
    case category(CrashCategory)
}

/// NSTextView-backed log viewer with inline tagging, gutter markers, and filtering.
struct LogViewerView: View {
    let logText: String
    let matches: [DiagnosisMatch]
    @Binding var filterMode: LogFilterMode
    @Binding var activeCategoryFilter: CrashCategory?
    @Binding var searchText: String
    @State private var appliedSearch = ""

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            LogTextView(
                logText: logText,
                matches: matches,
                filterMode: filterMode,
                searchText: appliedSearch
            )
        }
        .task(id: searchText) {
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            appliedSearch = searchText
        }
    }
}

// MARK: - Filter Bar

extension LogViewerView {
    private var filterBar: some View {
        HStack(spacing: 8) {
            filterButton(title: "Show all", mode: .all)
            filterButton(title: "Only tagged", mode: .tagged)
            filterButton(title: "Crash-related", mode: .crashRelated)
            Spacer()
            TextField("Search log\u{2026}", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
                .controlSize(.small)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(.windowBackgroundColor))
    }

    private func filterButton(title: String, mode: LogFilterMode) -> some View {
        Button {
            filterMode = mode
            if case .category = mode {} else {
                activeCategoryFilter = nil
            }
        } label: {
            Text(title)
                .font(.caption)
                .fontWeight(filterMode == mode ? .semibold : .regular)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    filterMode == mode
                        ? Color.accentColor.opacity(0.15)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - NSViewRepresentable

/// NSTextView wrapper providing high-performance log rendering with line tagging.
struct LogTextView: NSViewRepresentable {
    let logText: String
    let matches: [DiagnosisMatch]
    let filterMode: LogFilterMode
    let searchText: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.layoutManager?.allowsNonContiguousLayout = true
        context.coordinator.textView = textView
        updateNSView(scrollView, context: context)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            presentation: presentation,
            renderer: DiagnosticLogRenderer(
                logText: logText,
                matches: matches,
                filterMode: filterMode,
                searchText: searchText,
                appearanceName: scrollView.effectiveAppearance.name.rawValue
            ),
            scrollView: scrollView
        )
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.renderTask?.cancel()
    }

    private var presentation: Presentation {
        Presentation(
            text: logText,
            filter: filterMode,
            search: searchText,
            dark: colorScheme == .dark,
            highContrast: contrast == .increased,
            matches: matches.map {
                MatchKey(
                    id: $0.pattern.id,
                    line: $0.lineIndex,
                    text: $0.lineText,
                    category: $0.pattern.category,
                    severity: $0.pattern.severity
                )
            }
        )
    }

    struct MatchKey: Equatable {
        let id: String
        let line: Int
        let text: String
        let category: CrashCategory
        let severity: PatternSeverity
    }

    struct Presentation: Equatable {
        let text: String
        let filter: LogFilterMode
        let search: String
        let dark: Bool
        let highContrast: Bool
        let matches: [MatchKey]
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        weak var textView: NSTextView?
        var presentation: Presentation?
        var renderTask: Task<Void, Never>?

        fileprivate func update(presentation: Presentation, renderer: DiagnosticLogRenderer, scrollView: NSScrollView) {
            guard self.presentation != presentation else { return }
            self.presentation = presentation
            renderTask?.cancel()
            renderTask = Task { @MainActor [weak self, weak scrollView] in
                let work = Task.detached(priority: .userInitiated) { renderer.render() }
                let rendered = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
                guard !Task.isCancelled, let self, self.presentation == presentation,
                      let scrollView, let textView = self.textView, let storage = textView.textStorage
                else { return }
                let origin = scrollView.contentView.bounds.origin
                let selection = textView.selectedRanges
                storage.beginEditing()
                storage.setAttributedString(rendered.value)
                storage.endEditing()
                let validSelection = selection.filter { $0.rangeValue.upperBound <= storage.length }
                textView.selectedRanges = validSelection.isEmpty
                    ? [NSValue(range: NSRange(location: 0, length: 0))] : validSelection
                scrollView.contentView.scroll(to: origin)
            }
        }

        func scrollToLine(_ lineIndex: Int) {
            guard let textView, let storage = textView.textStorage else { return }
            let text = storage.string as NSString
            var currentLine = 0
            var charIndex = 0
            while currentLine < lineIndex, charIndex < text.length {
                let range = text.lineRange(for: NSRange(location: charIndex, length: 0))
                charIndex = NSMaxRange(range)
                currentLine += 1
            }
            let targetRange = NSRange(location: charIndex, length: 0)
            textView.scrollRangeToVisible(targetRange)
        }
    }
}
