//
//  WinetricksService+Catalog.swift
//  WhiskyKit
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

/// The categories the bundled `verbs.txt` groups winetricks verbs into.
public enum WinetricksCategoryID: String, CaseIterable, Codable, Sendable {
    case apps
    case benchmarks
    case dlls
    case fonts
    case games
    case settings
}

public struct WinetricksVerb: Identifiable, Hashable, Codable, Sendable {
    public var id: String {
        name
    }

    public let name: String
    public let description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

public struct WinetricksCategory: Identifiable, Hashable, Codable, Sendable {
    public var id: WinetricksCategoryID {
        category
    }

    public let category: WinetricksCategoryID
    public let verbs: [WinetricksVerb]

    public init(category: WinetricksCategoryID, verbs: [WinetricksVerb]) {
        self.category = category
        self.verbs = verbs
    }
}

public enum WinetricksCatalogError: Error, LocalizedError, Sendable {
    case resourceMissing

    public var errorDescription: String? {
        switch self {
        case .resourceMissing:
            "The bundled winetricks verb catalog is missing"
        }
    }
}

public extension WinetricksService {
    /// Parses the bundled `verbs.txt` index into the categories the UI shows.
    ///
    /// The file lists `===== <category> =====` headers followed by
    /// `<verb>  <description>` lines. Categories this frontend does not render
    /// are skipped, and malformed lines are ignored rather than producing an
    /// empty verb that could be sent back to winetricks.
    static func parseCatalog(_ contents: String) -> [WinetricksCategory] {
        var categories: [WinetricksCategory] = []
        var currentCategory: WinetricksCategoryID?
        var currentVerbs: [WinetricksVerb] = []

        func flush() {
            if let currentCategory {
                categories.append(WinetricksCategory(category: currentCategory, verbs: currentVerbs))
            }
            currentVerbs = []
        }

        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("=====") {
                flush()
                let name = line
                    .replacingOccurrences(of: "=====", with: "")
                    .trimmingCharacters(in: .whitespaces)
                currentCategory = WinetricksCategoryID(rawValue: name)
            } else if currentCategory != nil {
                let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard let name = parts.first.map(String.init) else { continue }
                let description = parts.count > 1
                    ? parts[1].trimmingCharacters(in: .whitespaces)
                    : ""
                currentVerbs.append(WinetricksVerb(name: name, description: description))
            }
        }
        flush()
        return categories
    }

    /// Reads the catalog shipped beside the app's winetricks and cabextract.
    static func catalog() throws -> [WinetricksCategory] {
        guard let url = WhiskyResources.tool("verbs.txt") else {
            throw WinetricksCatalogError.resourceMissing
        }
        let contents = try String(contentsOf: url, encoding: .utf8)
        return parseCatalog(contents)
    }

    /// Every verb the catalog advertises, for validating bridge requests.
    static func catalogVerbNames() throws -> Set<String> {
        let verbs = try catalog().flatMap(\.verbs).map(\.name)
        return Set(verbs)
    }
}
