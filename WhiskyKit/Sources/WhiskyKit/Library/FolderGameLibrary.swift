// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Folder identities are independent of the executable selected on first run.
public struct FolderGameLibrary: Codable, Sendable {
    public var roots: [String] = []
    public var executables: [String: String] = [:]
    public var knownFolders: [String] = []
    public var automaticMetadata = true
    public var initializedRoots: Set<String> = []
    public var pendingMetadata: Set<String> = []

    private enum CodingKeys: String, CodingKey {
        case roots, executables, knownFolders, automaticMetadata, initializedRoots, pendingMetadata
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        roots = try values.decodeIfPresent([String].self, forKey: .roots) ?? []
        executables = try values.decodeIfPresent([String: String].self, forKey: .executables) ?? [:]
        knownFolders = try values.decodeIfPresent([String].self, forKey: .knownFolders) ?? []
        automaticMetadata = try values.decodeIfPresent(Bool.self, forKey: .automaticMetadata) ?? true
        initializedRoots = try values.decodeIfPresent(Set<String>.self, forKey: .initializedRoots) ?? Set(roots)
        pendingMetadata = try values.decodeIfPresent(Set<String>.self, forKey: .pendingMetadata) ?? []
    }

    public init() {}

    public static func load(bottleURL: URL) throws -> Self {
        let url = location(bottleURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    public func save(bottleURL: URL) throws {
        try JSONEncoder().encode(self).write(to: Self.location(bottleURL), options: .atomic)
    }

    public static func key(for url: URL, bottleURL: URL) -> String {
        let path = url.standardizedFileURL.path
        let root = bottleURL.standardizedFileURL.path + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    public static func url(for key: String, bottleURL: URL) -> URL {
        key.hasPrefix("/") ? URL(fileURLWithPath: key) : bottleURL.appendingPathComponent(key)
    }

    /// Only direct child folders, never executable discovery or recursive walks.
    /// An unavailable root keeps its last known entries rather than deleting them.
    public mutating func scan(bottleURL: URL, steamDirectories: [URL]) -> [LibraryEntry] {
        let fm = FileManager.default
        var found = Set<String>()
        for rootKey in roots {
            let firstScan = !initializedRoots.contains(rootKey)
            let root = Self.url(for: rootKey, bottleURL: bottleURL)
            guard let children = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else {
                found.formUnion(knownFolders.filter {
                    Self.url(for: $0, bottleURL: bottleURL).deletingLastPathComponent().standardizedFileURL.path
                        == root.standardizedFileURL.path
                })
                continue
            }
            for child in children {
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let canonical = child.resolvingSymlinksInPath().standardizedFileURL.path
                // Do not treat a Steam install, its libraries, or an installed
                // Steam game as a second direct-executable launch path.
                guard !steamDirectories.contains(where: {
                    let path = $0.resolvingSymlinksInPath().standardizedFileURL.path
                    return canonical == path || canonical.hasPrefix(path + "/") || path.hasPrefix(canonical + "/")
                }) else { continue }
                let key = Self.key(for: child, bottleURL: bottleURL)
                found.insert(key)
                if firstScan && automaticMetadata { pendingMetadata.insert(key) }
            }
            initializedRoots.insert(rootKey)
        }
        knownFolders = found.sorted()
        return knownFolders.map { key in
            let folder = Self.url(for: key, bottleURL: bottleURL)
            return LibraryEntry(
                id: "folder:\(bottleURL.path):\(key)", name: folder.lastPathComponent,
                iconURL: executables[key].map { Self.url(for: $0, bottleURL: bottleURL) },
                bottleURL: bottleURL, source: .folder, launch: .program(folder)
            )
        }
    }

    public func executable(for folder: URL, bottleURL: URL) -> URL? {
        executables[Self.key(for: folder, bottleURL: bottleURL)].map { Self.url(for: $0, bottleURL: bottleURL) }
    }

    private static func location(_ bottle: URL) -> URL {
        bottle.appendingPathComponent("Folder Games.json")
    }
}

/// Library-only removal never changes pins, installed games or launch settings.
public struct LibraryVisibility: Codable, Sendable {
    public var hiddenIdentities: Set<String> = []
    public var includePinnedAndSteam = true
    public init() {}
    public static func load(bottleURL: URL) throws -> Self {
        let url = bottleURL.appendingPathComponent("Library Visibility.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    public func save(bottleURL: URL) throws {
        try JSONEncoder().encode(self).write(to: bottleURL.appendingPathComponent("Library Visibility.json"), options: .atomic)
    }
    public func includes(_ entry: LibraryEntry) -> Bool {
        !hiddenIdentities.contains(entry.metadataIdentity) && (includePinnedAndSteam || entry.source == .folder)
    }
}

public enum FolderGameMatching {
    /// Remove known packaging suffixes, not arbitrary bracketed subtitles.
    public static func query(_ name: String) -> String {
        var result = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result = result.replacingOccurrences(
            of: #"^(?:\s*[\[【][^\]】]*(?:汉化组|漢化組|汉化补丁|漢化補丁)[^\]】]*[\]】]\s*)+"#,
            with: "", options: .regularExpression
        )
        while true {
            let cleaned = result.replacingOccurrences(
            of: #"(?i)\s*(?:[\[【(（]?\s*(?:(?:官方)?(?:简体中文|繁体中文|中文)|汉化|漢化|免安装|免安裝|硬盘|硬盤|绿色|綠色)(?:版|补丁|補丁)?\s*[\]】)）]?|[\[【(（]?v\d+(?:\.\d+)+(?:[a-z])?[\]】)）]?)\s*$"#,
            with: "", options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned == result || cleaned.isEmpty { return result }
            result = cleaned
        }
    }

    public static func normalized(_ text: String) -> String {
        let simplified = text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
        return simplified.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    /// All names participate, while display language remains independent.
    public static func ranked(query: String, games: [GameMetadata]) -> [GameMetadata] {
        games.enumerated().sorted {
            let lhs = score(query: query, game: $0.element)
            let rhs = score(query: query, game: $1.element)
            return lhs == rhs ? $0.offset < $1.offset : lhs > rhs
        }.map(\.element)
    }

    /// Prefer exact identities across sources, then accept only a clearly leading
    /// long-name near-match. Source errors leave other providers available.
    public static func candidate(query: String, results: [GameMetadataSearchResult],
                                 sources: [GameMetadataSource]) -> GameMetadata? {
        let needle = normalized(query)
        guard !needle.isEmpty else { return nil }
        let available = sources.compactMap { source in
            results.first { $0.source == source && $0.error == nil }
        }
        for result in available {
            let matches = result.games.filter { game in
                game.matchingTitles.contains { normalized($0) == needle && edition(query) == edition($0) }
            }
            if matches.count > 1 { return nil }
            if let match = matches.first { return match }
        }
        for result in available {
            let candidates = ranked(query: query, games: result.games)
            guard let first = candidates.first else { continue }
            let best = score(query: query, game: first)
            let second = candidates.dropFirst().first.map { score(query: query, game: $0) } ?? 0
            if best >= 0.92 && best - second >= 0.12 { return first }
        }
        return nil
    }

    private static func score(query: String, game: GameMetadata) -> Double {
        let needle = normalized(query)
        guard !needle.isEmpty else { return 0 }
        return game.matchingTitles.map { title in
            let name = normalized(title)
            guard edition(query) == edition(title) else { return 0.0 }
            if name == needle { return 1.0 }
            // Short names and different editions need explicit confirmation.
            guard min(name.count, needle.count) >= 8,
                  max(name.count, needle.count) <= 256 else { return 0.0 }
            let lhs = Array(needle), rhs = Array(name)
            var previous = Array(0...rhs.count)
            for (i, left) in lhs.enumerated() {
                var current = [i + 1] + Array(repeating: 0, count: rhs.count)
                for (j, right) in rhs.enumerated() {
                    current[j + 1] = min(current[j] + 1, previous[j + 1] + 1,
                                         previous[j] + (left == right ? 0 : 1))
                }
                previous = current
            }
            return 1.0 - Double(previous[rhs.count]) / Double(max(lhs.count, rhs.count))
        }.max() ?? 0
    }

    private static func edition(_ text: String) -> [String] {
        let text = text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let pattern = #"\d+|\b(?:ii|iii|iv|vi|vii|viii|ix|fd|complete|remake|remaster(?:ed)?)\b|\+|ファンディスク|重制|重製|重置|完全版"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}
