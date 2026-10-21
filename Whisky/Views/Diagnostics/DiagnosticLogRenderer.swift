//
//  DiagnosticLogRenderer.swift
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
import Foundation
import WhiskyKit

struct RenderedDiagnosticLog: @unchecked Sendable {
    let value: NSAttributedString
}

struct DiagnosticLogRenderer: Sendable {
    let logText: String
    let matches: [DiagnosisMatch]
    let filterMode: LogFilterMode
    let searchText: String

    // MARK: - Content Application

    let appearanceName: String

    func render() -> RenderedDiagnosticLog {
        var result = RenderedDiagnosticLog(value: NSAttributedString(string: ""))
        if let appearance = NSAppearance(named: NSAppearance.Name(rawValue: appearanceName)) {
            appearance.performAsCurrentDrawingAppearance { result = renderContent() }
        } else {
            result = renderContent()
        }
        return result
    }

    private func renderContent() -> RenderedDiagnosticLog {
        let allLines = logText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let matchedLineIndices = Set(matches.filter { match in
            switch filterMode {
            case .crashRelated: match.pattern.category == .coreCrashFatal || match.pattern.category == .graphics
            case let .category(category): match.pattern.category == category
            default: true
            }
        }.map(\.lineIndex))

        let filteredLines: [(index: Int, text: String)] = filterLines(
            allLines: allLines,
            matchedIndices: matchedLineIndices
        )

        let matchLookup = buildMatchLookup()
        let attributed = buildAttributedString(
            filteredLines: filteredLines,
            matchLookup: matchLookup
        )

        return RenderedDiagnosticLog(value: NSAttributedString(attributedString: attributed))
    }

    private func filterLines(
        allLines: [String],
        matchedIndices: Set<Int>
    ) -> [(index: Int, text: String)] {
        allLines.enumerated()
            .filter { passesFilter(lineIndex: $0.offset, lineText: $0.element, matchedIndices: matchedIndices) }
            .map { (index: $0.offset, text: $0.element) }
    }

    private func passesFilter(lineIndex: Int, lineText: String, matchedIndices: Set<Int>) -> Bool {
        // Search text filter
        if !searchText.isEmpty, !lineText.localizedCaseInsensitiveContains(searchText) {
            return false
        }

        switch filterMode {
        case .all:
            return true
        case .tagged:
            return matchedIndices.contains(lineIndex)
        case .crashRelated, .category:
            return matchedIndices.contains(lineIndex)
        }
    }
}

// MARK: - Match Lookup

extension DiagnosticLogRenderer {
    private func buildMatchLookup() -> [Int: DiagnosisMatch] {
        var lookup: [Int: DiagnosisMatch] = [:]
        for match in matches {
            if let existing = lookup[match.lineIndex] {
                if match.pattern.severity > existing.pattern.severity {
                    lookup[match.lineIndex] = match
                }
            } else {
                lookup[match.lineIndex] = match
            }
        }
        return lookup
    }
}

// MARK: - Attributed String Builder

extension DiagnosticLogRenderer {
    private func buildAttributedString(
        filteredLines: [(index: Int, text: String)],
        matchLookup: [Int: DiagnosisMatch]
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let baseFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let baseColor = NSColor.textColor
        let baseParagraph = NSMutableParagraphStyle()
        baseParagraph.lineSpacing = 1

        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: baseColor,
            .paragraphStyle: baseParagraph
        ]

        for (idx, entry) in filteredLines.enumerated() {
            if Task.isCancelled {
                break
            }
            let lineNumber = String(format: "%5d ", entry.index + 1)
            var lineContent: String

            if let match = matchLookup[entry.index] {
                let marker = gutterMarker(for: match)
                lineContent = "\(lineNumber)\(marker) \(entry.text)"
            } else {
                lineContent = "\(lineNumber)  \(entry.text)"
            }

            if idx < filteredLines.count - 1 {
                lineContent += "\n"
            }

            let lineAttr = NSMutableAttributedString(string: lineContent, attributes: baseAttributes)

            // Apply background tint for tagged lines
            if let match = matchLookup[entry.index] {
                let bgColor = backgroundColor(for: match)
                let fullRange = NSRange(location: 0, length: lineAttr.length)
                lineAttr.addAttribute(.backgroundColor, value: bgColor, range: fullRange)

                // Color the gutter marker
                let markerColor = markerColor(for: match)
                let markerStart = lineNumber.count
                let markerLength = 1
                if markerStart + markerLength <= lineAttr.length {
                    let markerRange = NSRange(location: markerStart, length: markerLength)
                    lineAttr.addAttribute(.foregroundColor, value: markerColor, range: markerRange)
                }
            }

            result.append(lineAttr)
        }

        return result
    }

    private func gutterMarker(for match: DiagnosisMatch) -> String {
        switch match.pattern.category {
        case .coreCrashFatal:
            "\u{25CF}" // filled circle
        case .graphics:
            "\u{25CF}"
        case .dependenciesLoading:
            "\u{25CF}"
        case .prefixFilesystem:
            "\u{25CF}"
        case .networkingLaunchers:
            "\u{25CF}"
        case .antiCheatUnsupported:
            "\u{25CF}"
        case .otherUnknown:
            "\u{25CB}" // open circle
        }
    }

    private func backgroundColor(for match: DiagnosisMatch) -> NSColor {
        switch match.pattern.category {
        case .coreCrashFatal:
            NSColor.systemRed.withAlphaComponent(0.08)
        case .graphics:
            NSColor.systemOrange.withAlphaComponent(0.08)
        default:
            if match.pattern.severity >= .error {
                NSColor.systemRed.withAlphaComponent(0.06)
            } else if match.pattern.severity >= .warning {
                NSColor.systemYellow.withAlphaComponent(0.06)
            } else {
                NSColor.clear
            }
        }
    }

    private func markerColor(for match: DiagnosisMatch) -> NSColor {
        switch match.pattern.category {
        case .coreCrashFatal:
            .systemRed
        case .graphics:
            .systemOrange
        case .dependenciesLoading:
            .systemBlue
        case .prefixFilesystem:
            .systemPurple
        case .networkingLaunchers:
            .systemCyan
        case .antiCheatUnsupported:
            .systemGray
        case .otherUnknown:
            .secondaryLabelColor
        }
    }
}
