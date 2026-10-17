// swiftlint:disable file_length
//
//  FolderGameLibrary.swift
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

/// Folder identities are independent of the executable selected on first run.
public struct FolderGameLibrary: Codable, Sendable { // swiftlint:disable:this type_body_length
    public var roots: [String] = []
    public var assignedFolders: [String] = []
    public var excludedFolders: Set<String> = []
    public var executables: [String: String] = [:]
    public var knownFolders: [String] = []
    public var automaticMetadata = true
    public var initializedRoots: Set<String> = []
    public var pendingMetadata: Set<String> = []

    private enum CodingKeys: String, CodingKey {
        case roots, assignedFolders, excludedFolders, executables, knownFolders
        case automaticMetadata, initializedRoots, pendingMetadata
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        roots = try values.decodeIfPresent([String].self, forKey: .roots) ?? []
        assignedFolders = try values.decodeIfPresent([String].self, forKey: .assignedFolders) ?? []
        excludedFolders = try values.decodeIfPresent(Set<String>.self, forKey: .excludedFolders) ?? []
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

    private func isExcluded(_ url: URL, key: String, bottleURL: URL) -> Bool {
        if excludedFolders.contains(key) || excludedFolders.contains(url.standardizedFileURL.path) {
            return true
        }
        let targetPath = url.standardizedFileURL.path
        return excludedFolders.contains {
            Self.url(for: $0, bottleURL: bottleURL).standardizedFileURL.path == targetPath
        }
    }

    private func isSteamDirectory(_ canonicalPath: String, steamDirectories: [URL]) -> Bool {
        steamDirectories.contains {
            let path = $0.resolvingSymlinksInPath().standardizedFileURL.path
            return canonicalPath == path || canonicalPath.hasPrefix(path + "/") || path.hasPrefix(canonicalPath + "/")
        }
    }

    // swiftlint:disable cyclomatic_complexity function_body_length
    /// Only direct child folders, never executable discovery or recursive walks.
    /// An unavailable root keeps its last known entries rather than deleting them.
    public mutating func scan(bottleURL: URL, steamDirectories: [URL]) -> [LibraryEntry] {
        let fileManager = FileManager.default
        var found = Set<String>()
        for rootKey in roots {
            let firstScan = !initializedRoots.contains(rootKey)
            let root = Self.url(for: rootKey, bottleURL: bottleURL)
            guard let children = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            else {
                found.formUnion(knownFolders.filter {
                    let childURL = Self.url(for: $0, bottleURL: bottleURL)
                    return childURL.deletingLastPathComponent().standardizedFileURL.path
                        == root.standardizedFileURL.path
                        && !isExcluded(childURL, key: $0, bottleURL: bottleURL)
                })
                continue
            }
            for child in children {
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true
                else { continue }
                let canonical = child.resolvingSymlinksInPath().standardizedFileURL.path
                // Do not treat a Steam install, its libraries, or an installed
                // Steam game as a second direct-executable launch path.
                guard !isSteamDirectory(canonical, steamDirectories: steamDirectories) else { continue }
                let key = Self.key(for: child, bottleURL: bottleURL)
                guard !isExcluded(child, key: key, bottleURL: bottleURL) else { continue }
                found.insert(key)
                if firstScan, automaticMetadata {
                    pendingMetadata.insert(key)
                }
            }
            initializedRoots.insert(rootKey)
        }
        for assignedKey in assignedFolders {
            let folder = Self.url(for: assignedKey, bottleURL: bottleURL)
            let normalizedKey = Self.key(for: folder, bottleURL: bottleURL)
            guard !isExcluded(folder, key: normalizedKey, bottleURL: bottleURL) else { continue }
            if let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let canonical = folder.resolvingSymlinksInPath().standardizedFileURL.path
                guard !isSteamDirectory(canonical, steamDirectories: steamDirectories) else { continue }
                found.insert(normalizedKey)
            } else if knownFolders.contains(normalizedKey) || knownFolders.contains(assignedKey) {
                found.insert(normalizedKey)
            }
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

    // swiftlint:enable cyclomatic_complexity function_body_length

    public func executable(for folder: URL, bottleURL: URL) -> URL? {
        executables[Self.key(for: folder, bottleURL: bottleURL)].map { Self.url(for: $0, bottleURL: bottleURL) }
    }

    /// Reassigns a single folder game from `sourceBottleURL` to `targetBottleURL`,
    /// preserving its chosen executable, pending metadata status, and per-program settings.
    public static func moveFolder(
        _ folder: URL,
        from sourceBottleURL: URL,
        to targetBottleURL: URL
    ) throws {
        guard sourceBottleURL.standardizedFileURL != targetBottleURL.standardizedFileURL else { return }
        var sourceLib = try load(bottleURL: sourceBottleURL)
        var targetLib = try load(bottleURL: targetBottleURL)

        let canonicalFolder = folder.standardizedFileURL
        let sourceKey = key(for: canonicalFolder, bottleURL: sourceBottleURL)
        let targetKey = key(for: canonicalFolder, bottleURL: targetBottleURL)
        let parentPath = canonicalFolder.deletingLastPathComponent().path

        let isUnderSourceRoot = sourceLib.roots.contains {
            url(for: $0, bottleURL: sourceBottleURL).standardizedFileURL.path == parentPath
        }
        sourceLib.assignedFolders.removeAll {
            url(for: $0, bottleURL: sourceBottleURL).standardizedFileURL == canonicalFolder
        }
        if isUnderSourceRoot {
            sourceLib.excludedFolders.insert(sourceKey)
        }
        sourceLib.knownFolders.removeAll {
            url(for: $0, bottleURL: sourceBottleURL).standardizedFileURL == canonicalFolder
        }
        let wasPending = sourceLib.pendingMetadata.remove(sourceKey) != nil

        if let exeURL = sourceLib.executable(for: canonicalFolder, bottleURL: sourceBottleURL) {
            targetLib.executables[targetKey] = key(for: exeURL, bottleURL: targetBottleURL)
            migrateProgramSettings(for: exeURL, from: sourceBottleURL, to: targetBottleURL)
        }
        sourceLib.executables.removeValue(forKey: sourceKey)

        targetLib.excludedFolders = targetLib.excludedFolders.filter {
            url(for: $0, bottleURL: targetBottleURL).standardizedFileURL != canonicalFolder
        }
        let isUnderTargetRoot = targetLib.roots.contains {
            url(for: $0, bottleURL: targetBottleURL).standardizedFileURL.path == parentPath
        }
        if !isUnderTargetRoot, !targetLib.assignedFolders.contains(targetKey) {
            targetLib.assignedFolders.append(targetKey)
        }
        if !targetLib.knownFolders.contains(targetKey) {
            targetLib.knownFolders.append(targetKey)
            targetLib.knownFolders.sort()
        }
        if wasPending, targetLib.automaticMetadata {
            targetLib.pendingMetadata.insert(targetKey)
        }

        try targetLib.save(bottleURL: targetBottleURL)
        try sourceLib.save(bottleURL: sourceBottleURL)

        var targetVisibility = try LibraryVisibility.load(bottleURL: targetBottleURL)
        if targetVisibility.hiddenIdentities.remove("program:" + targetKey) != nil {
            try targetVisibility.save(bottleURL: targetBottleURL)
        }
    }

    /// Moves an entire scanned root folder and its discovered games from `sourceBottleURL` to `targetBottleURL`.
    public static func moveRoot( // swiftlint:disable:this function_body_length
        _ rootKey: String,
        from sourceBottleURL: URL,
        to targetBottleURL: URL
    ) async throws {
        guard sourceBottleURL.standardizedFileURL != targetBottleURL.standardizedFileURL else { return }
        var sourceLib = try load(bottleURL: sourceBottleURL)
        var targetLib = try load(bottleURL: targetBottleURL)

        let rootURL = url(for: rootKey, bottleURL: sourceBottleURL).standardizedFileURL
        let targetRootKey = key(for: rootURL, bottleURL: targetBottleURL)

        sourceLib.roots.removeAll {
            url(for: $0, bottleURL: sourceBottleURL).standardizedFileURL == rootURL
        }
        let wasInitialized = sourceLib.initializedRoots.remove(rootKey) != nil
        if !targetLib.roots.contains(targetRootKey) {
            targetLib.roots.append(targetRootKey)
        }
        if wasInitialized {
            targetLib.initializedRoots.insert(targetRootKey)
        }

        let exclusions = sourceLib.excludedFolders.filter {
            url(for: $0, bottleURL: sourceBottleURL).deletingLastPathComponent().standardizedFileURL == rootURL
        }
        sourceLib.excludedFolders.subtract(exclusions)
        targetLib.excludedFolders.formUnion(exclusions.map {
            key(for: url(for: $0, bottleURL: sourceBottleURL), bottleURL: targetBottleURL)
        })

        let sourceStore = GameMetadataStore(directory: sourceBottleURL.appendingPathComponent("Game Metadata"))
        let targetStore = GameMetadataStore(directory: targetBottleURL.appendingPathComponent("Game Metadata"))

        let matchingSourceKeys = sourceLib.knownFolders.filter {
            url(for: $0, bottleURL: sourceBottleURL).deletingLastPathComponent().standardizedFileURL == rootURL
        }
        var targetVisibility = try LibraryVisibility.load(bottleURL: targetBottleURL)
        var visibilityChanged = false
        for folderKey in matchingSourceKeys {
            let folderURL = url(for: folderKey, bottleURL: sourceBottleURL).standardizedFileURL
            let newFolderKey = key(for: folderURL, bottleURL: targetBottleURL)
            try await sourceStore.copyEntry(
                for: "program:" + folderKey, to: targetStore, targetIdentity: "program:" + newFolderKey
            )
            sourceLib.knownFolders.removeAll { $0 == folderKey }
            if !targetLib.knownFolders.contains(newFolderKey) {
                targetLib.knownFolders.append(newFolderKey)
            }
            if targetVisibility.hiddenIdentities.remove("program:" + newFolderKey) != nil {
                visibilityChanged = true
            }
            if sourceLib.pendingMetadata.remove(folderKey) != nil, targetLib.automaticMetadata {
                targetLib.pendingMetadata.insert(newFolderKey)
            }
            if let exeURL = sourceLib.executable(for: folderURL, bottleURL: sourceBottleURL) {
                targetLib.executables[newFolderKey] = key(for: exeURL, bottleURL: targetBottleURL)
                migrateProgramSettings(for: exeURL, from: sourceBottleURL, to: targetBottleURL)
                sourceLib.executables.removeValue(forKey: folderKey)
            }
        }
        targetLib.knownFolders.sort()

        try targetLib.save(bottleURL: targetBottleURL)
        try sourceLib.save(bottleURL: sourceBottleURL)
        if visibilityChanged {
            try targetVisibility.save(bottleURL: targetBottleURL)
        }
    }

    public static func migrateProgramSettings(
        for executableURL: URL,
        from sourceBottleURL: URL,
        to targetBottleURL: URL
    ) {
        let fileManager = FileManager.default
        let sourceLocations = Program.settingsLocations(
            for: executableURL, bottleURL: sourceBottleURL, legacyName: executableURL.lastPathComponent
        )
        let targetLocations = Program.settingsLocations(
            for: executableURL, bottleURL: targetBottleURL, legacyName: executableURL.lastPathComponent
        )
        let sourceFile: URL? = if fileManager.fileExists(atPath: sourceLocations.identity.path(percentEncoded: false)) {
            sourceLocations.identity
        } else if fileManager.fileExists(atPath: sourceLocations.legacy.path(percentEncoded: false)) {
            sourceLocations.legacy
        } else {
            nil
        }
        guard let sourceFile,
              !fileManager.fileExists(atPath: targetLocations.identity.path(percentEncoded: false))
        else { return }
        try? fileManager.createDirectory(
            at: targetLocations.identity.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? fileManager.copyItem(at: sourceFile, to: targetLocations.identity)
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
        try JSONEncoder().encode(self).write(
            to: bottleURL.appendingPathComponent("Library Visibility.json"),
            options: .atomic
        )
    }

    public func includes(_ entry: LibraryEntry) -> Bool {
        !hiddenIdentities.contains(entry.metadataIdentity) && (includePinnedAndSteam || entry.source == .folder)
    }
}

public enum FolderGameMatching {
    private static let shinjitaiMap: [Character: Character] = [
        "桜": "樱", "剣": "剑", "涙": "泪", "姫": "姬", "悪": "恶", "獣": "兽", "黒": "黑", "竜": "龙",
        "団": "团", "図": "图", "囲": "围", "圏": "圈", "発": "发", "髪": "发", "顔": "颜", "頼": "赖",
        "顕": "显", "駅": "驿", "駆": "驱", "騒": "骚", "験": "验", "髄": "髓", "鴎": "鸥", "黙": "默",
        "齢": "龄", "歩": "步", "気": "气", "沢": "泽", "浜": "滨", "渕": "渊", "満": "满", "滅": "灭",
        "滝": "泷", "滞": "滞", "漬": "渍", "漸": "渐", "潜": "潜", "潟": "泻", "渋": "涩", "渓": "溪",
        "渉": "涉", "猟": "猎", "献": "献", "畳": "叠", "砕": "碎", "祷": "祷", "禍": "祸", "穂": "穗",
        "箇": "个", "節": "节", "粋": "粹", "粛": "肃", "粧": "妆", "糧": "粮", "経": "经", "絵": "绘",
        "絶": "绝", "継": "继", "続": "续", "総": "总", "緑": "绿", "緒": "绪", "線": "线", "締": "缔",
        "編": "编", "緩": "缓", "練": "练", "縁": "缘", "縄": "绳", "縦": "纵", "縫": "缝", "縮": "缩",
        "績": "绩", "繊": "纤", "繋": "系", "繍": "绣", "織": "织", "譲": "让", "醸": "酿", "鎌": "镰",
        "鎮": "镇", "鉄": "铁", "鉱": "矿", "鋼": "钢", "録": "录", "銭": "钱", "錬": "炼", "錯": "错",
        "鍵": "键", "鍛": "锻", "闘": "斗", "陥": "陷", "険": "险", "隠": "隐", "隣": "邻", "隷": "隶",
        "雑": "杂", "難": "难", "霊": "灵", "静": "静", "響": "响", "頂": "顶", "頃": "顷", "順": "顺",
        "須": "须", "預": "预", "頑": "顽", "頓": "顿", "領": "领", "頭": "头", "頬": "颊", "頻": "频",
        "題": "题", "額": "额", "願": "愿", "類": "类", "顧": "顾", "風": "风", "飛": "飞", "飢": "饥",
        "飯": "饭", "飲": "饮", "飼": "饲", "飽": "饱", "飾": "饰", "餅": "饼", "養": "养", "餌": "饵",
        "餓": "饿", "館": "馆", "駄": "驮", "駐": "驻", "駒": "驹", "騎": "骑", "騰": "腾", "驚": "惊",
        "鶏": "鸡", "鶴": "鹤", "鷲": "鹫", "鷹": "鹰", "麗": "丽", "麺": "面", "斉": "齐", "歯": "齿",
        "亀": "龟", "転": "转", "伝": "传", "芸": "艺", "広": "广", "応": "应", "帰": "归", "変": "变",
        "楽": "乐", "様": "样", "権": "权", "歓": "欢", "残": "残", "殻": "壳", "毎": "每", "氷": "冰",
        "決": "决", "況": "况", "済": "济", "涼": "凉", "渇": "渴", "湾": "湾", "灯": "灯", "炉": "炉",
        "為": "为", "焼": "烧", "熱": "热", "愛": "爱", "状": "状", "独": "独", "狭": "狭", "獄": "狱",
        "現": "现", "産": "产", "画": "画", "異": "异", "疎": "疏", "尽": "尽", "監": "监", "盤": "盘",
        "県": "县", "矯": "矫", "砲": "炮", "確": "确", "礎": "础", "礼": "礼", "稲": "稻", "穀": "谷",
        "積": "积", "穏": "稳", "穫": "获", "窓": "窗", "窮": "穷", "窯": "窑", "競": "竞"
    ]

    /// Remove known packaging suffixes, not arbitrary bracketed subtitles.
    public static func query(_ name: String) -> String {
        var result = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result = result.replacingOccurrences(
            // swiftlint:disable:next line_length
            of: #"(?i)^(?:\s*[\[【](?:[^\]】]*(?:汉化组|漢化組|汉化补丁|漢化補丁|汉化|漢化|翻译|翻訳|字幕组|字幕組)[^\]】]*|(?:19|20)?\d{6}|[rv]j\d+|krkr\d?|ons|renpy|pc|dl版|パッケージ版)[\]】]\s*)+"#,
            with: "", options: .regularExpression
        )
        while true {
            let cleaned = result.replacingOccurrences(
                // swiftlint:disable:next line_length
                of: #"(?i)\s*(?:[\[【(（]?\s*(?:(?:官方)?(?:简体中文|繁体中文|简繁中文|簡繁中文|简中|簡中|繁中|中文)|汉化|漢化|免安装|免安裝|硬盘|硬盤|绿色|綠色|无修|無修|步兵|全cg|全特典|整合|内嵌|內嵌|体验|体験|试玩|試玩)(?:绿色|綠色|免安装|免安裝|硬盘|硬盤)?(?:版|补丁|補丁)?\s*[\]】)）]?|[\[【(（]\s*(?:chs|cht|sc|tc|cn|jp|en|pc|dl版|パッケージ版|krkr\d?|ons)\s*[\]】)）]|[\[【(（]?(?:v\d+(?:\.\d+)+(?:[a-z])?|(?:ver\.?|version|build)\s*\d+(?:\.\d+)*(?:[a-z])?)[\]】)）]?)\s*$"#,
                with: "", options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned == result || cleaned.isEmpty {
                return result
            }
            result = cleaned
        }
    }

    public static func normalized(_ text: String) -> String {
        let simplified = text.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? text
        let unified = String(simplified.map { shinjitaiMap[$0] ?? $0 })
        var folded = unified.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let replacements: [(String, String)] = [
            (#"\bii\b"#, "2"), (#"\biii\b"#, "3"), (#"\biv\b"#, "4"),
            (#"\bvi\b"#, "6"), (#"\bvii\b"#, "7"), (#"\bviii\b"#, "8"), (#"\bix\b"#, "9"),
            (#"\bremastered\b"#, "remaster"),
            (#"ファンディスク"#, "fd"),
            (#"(?:重制|重製|重置)(?:版)?"#, "remake"),
            (#"完全版"#, "complete")
        ]
        for (pattern, replacement) in replacements {
            folded = folded.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    /// All names participate, while display language remains independent.
    public static func ranked(query: String, games: [GameMetadata]) -> [GameMetadata] {
        games.enumerated().sorted {
            let lhs = rankingScore(query: query, game: $0.element)
            let rhs = rankingScore(query: query, game: $1.element)
            return lhs == rhs ? $0.offset < $1.offset : lhs > rhs
        }.map(\.element)
    }

    public static func exactMatches(query: String, in games: [GameMetadata]) -> [GameMetadata] {
        let needle = normalized(query)
        guard !needle.isEmpty else { return [] }
        let queryEdition = edition(query)
        return games.filter { game in
            game.matchingTitles.contains { normalized($0) == needle && queryEdition == edition($0) }
        }
    }

    /// Prefer exact identities across sources, then accept only a clearly leading
    /// long-name near-match. Source errors leave other providers available.
    public static func candidate(
        query: String,
        results: [GameMetadataSearchResult],
        sources: [GameMetadataSource]
    ) -> GameMetadata? {
        let needle = normalized(query)
        guard !needle.isEmpty else { return nil }
        let available = sources.compactMap { source in
            results.first { $0.source == source && $0.error == nil }
        }
        for result in available {
            let matches = exactMatches(query: query, in: result.games)
            if matches.count > 1 {
                return nil
            }
            if let match = matches.first {
                return match
            }
        }
        for result in available {
            let candidates = result.games.enumerated().sorted {
                let lhs = score(query: query, game: $0.element)
                let rhs = score(query: query, game: $1.element)
                return lhs == rhs ? $0.offset < $1.offset : lhs > rhs
            }.map(\.element)
            guard let first = candidates.first else { continue }
            let best = score(query: query, game: first)
            let second = candidates.dropFirst().first.map { score(query: query, game: $0) } ?? 0
            if best >= 0.92, best - second >= 0.12 {
                return first
            }
        }
        return nil
    }

    private static func score(query: String, game: GameMetadata) -> Double {
        let needle = normalized(query)
        guard !needle.isEmpty else { return 0 }
        let queryEdition = edition(query)
        return game.matchingTitles.map { title in
            let name = normalized(title)
            guard queryEdition == edition(title) else { return 0.0 }
            if name == needle {
                return 1.0
            }
            // Short names and different editions need explicit confirmation.
            // CJK characters carry higher information density than Latin letters.
            let minRequired = containsCJK(needle) && containsCJK(name) ? 6 : 8
            guard min(name.count, needle.count) >= minRequired,
                  max(name.count, needle.count) <= 256
            else { return 0.0 }
            return editSimilarity(needle, name)
        }.max() ?? 0
    }

    private static func rankingScore(query: String, game: GameMetadata) -> Double {
        let needle = normalized(query)
        guard !needle.isEmpty else { return 0 }
        let queryEdition = edition(query)
        return game.matchingTitles.map { title in
            let name = normalized(title)
            guard !name.isEmpty, max(name.count, needle.count) <= 256 else { return 0.0 }
            let editionPenalty = queryEdition == edition(title) ? 1.0 : 0.75
            if name == needle {
                return 1.0 * editionPenalty
            }
            return editSimilarity(needle, name) * editionPenalty
        }.max() ?? 0
    }

    private static func editSimilarity(_ lhsText: String, _ rhsText: String) -> Double {
        let lhs = Array(lhsText), rhs = Array(rhsText)
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        var previous = Array(0 ... rhs.count)
        for (rowIndex, left) in lhs.enumerated() {
            var current = [rowIndex + 1] + Array(repeating: 0, count: rhs.count)
            for (colIndex, right) in rhs.enumerated() {
                current[colIndex + 1] = min(
                    current[colIndex] + 1,
                    previous[colIndex + 1] + 1,
                    previous[colIndex] + (left == right ? 0 : 1)
                )
            }
            previous = current
        }
        return 1.0 - Double(previous[rhs.count]) / Double(max(lhs.count, rhs.count))
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3040 ... 0x9FFF).contains($0.value) }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func edition(_ text: String) -> [String] {
        let text = text.folding(
            options: [.caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let pattern = #"\d+|\b(?:ii|iii|iv|vi|vii|viii|ix|fd|complete|remake|remaster(?:ed)?)\b"#
            + #"|\+|ファンディスク|重制|重製|重置|完全版"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            switch String(text[range]) {
            case "ii": return "2"
            case "iii": return "3"
            case "iv": return "4"
            case "vi": return "6"
            case "vii": return "7"
            case "viii": return "8"
            case "ix": return "9"
            case "ファンディスク": return "fd"
            case "重制", "重製", "重置": return "remake"
            case "remastered": return "remaster"
            case "完全版": return "complete"
            case let token: return token
            }
        }
    }
}
