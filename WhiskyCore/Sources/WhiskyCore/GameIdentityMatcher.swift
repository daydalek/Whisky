// swiftlint:disable file_length
//
//  GameIdentityMatcher.swift
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

/// Metadata about a program used for matching against the game database.
///
/// Contains the identifiers and attributes extracted from a program's
/// executable file, install path, and associated Steam metadata.
public struct ProgramMetadata: Sendable {
    /// The executable filename (e.g., "eldenring.exe").
    public let exeName: String
    /// The URL to the executable file, if available.
    public let exeURL: URL?
    /// The file size of the executable in bytes.
    public let fileSize: Int64?
    /// The PE COFF header timestamp of the executable.
    public let peTimestamp: Date?
    /// The Steam App ID, if discovered from manifest or steam_appid.txt.
    public let steamAppId: Int?
    /// The install path of the program within the Wine prefix.
    public let installPath: String?

    public init(
        exeName: String,
        exeURL: URL? = nil,
        fileSize: Int64? = nil,
        peTimestamp: Date? = nil,
        steamAppId: Int? = nil,
        installPath: String? = nil
    ) {
        self.exeName = exeName
        self.exeURL = exeURL
        self.fileSize = fileSize
        self.peTimestamp = peTimestamp
        self.steamAppId = steamAppId
        self.installPath = installPath
    }
}

public struct ExeFingerprint: Codable, Sendable, Equatable {
    /// The SHA-256 hash of the executable file, if computed.
    public let sha256: String?
    /// The file size in bytes.
    public let fileSize: Int64?
    /// The PE COFF header timestamp.
    public let peTimestamp: Date?

    public init(sha256: String? = nil, fileSize: Int64? = nil, peTimestamp: Date? = nil) {
        self.sha256 = sha256
        self.fileSize = fileSize
        self.peTimestamp = peTimestamp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
        self.fileSize = try container.decodeIfPresent(Int64.self, forKey: .fileSize)
        self.peTimestamp = try container.decodeIfPresent(Date.self, forKey: .peTimestamp)
    }
}

public enum MatchTier: Int, Codable, Sendable, Comparable {
    /// Definitive match via Steam App ID or executable fingerprint.
    case fuzzy = 1
    /// High-confidence match via executable name or path pattern.
    case strongHeuristic = 2
    /// Definitive match via hard identifier.
    case hardIdentifier = 3

    public static func < (lhs: MatchTier, rhs: MatchTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Identity fields shared by the native and portable GameDB adapters.
public struct GameIdentityRecord: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let aliases: [String]?
    public let steamAppId: Int?
    public let exeNames: [String]?
    public let exeFingerprints: [ExeFingerprint]?
    public let pathPatterns: [String]?

    public init(
        id: String,
        title: String,
        aliases: [String]? = nil,
        steamAppId: Int? = nil,
        exeNames: [String]? = nil,
        exeFingerprints: [ExeFingerprint]? = nil,
        pathPatterns: [String]? = nil
    ) {
        self.id = id
        self.title = title
        self.aliases = aliases
        self.steamAppId = steamAppId
        self.exeNames = exeNames
        self.exeFingerprints = exeFingerprints
        self.pathPatterns = pathPatterns
    }
}

public struct GameIdentityMatch: Sendable {
    public let index: Int
    public let entry: GameIdentityRecord
    public let confidence: Double
    public let tier: MatchTier
    public let explanation: String
}

public enum GameIdentityMatcher {
    // MARK: - Configuration

    /// Minimum confidence score for a result to be included.
    private static let minimumThreshold: Double = 0.3

    /// Minimum gap between top two scores for bestMatch to return a result.
    private static let ambiguityGap: Double = 0.1

    /// Minimum confidence for bestMatch to return a result.
    private static let bestMatchMinimum: Double = 0.7

    /// Penalty applied to generic executable names.
    private static let genericPenalty: Double = -0.3

    /// Executable names that are too generic to reliably identify a game.
    private static let genericExeNames: Set<String> = [
        "launcher.exe", "setup.exe", "start.exe", "game.exe",
        "app.exe", "install.exe", "uninstall.exe", "updater.exe",
        "config.exe", "settings.exe", "crash_reporter.exe",
        "ue4-win64-shipping.exe", "unity.exe", "unitycrashhandler64.exe"
    ]

    // MARK: - Public API

    /// Scores all entries against the given metadata and returns matches above threshold.
    ///
    /// Results are sorted by confidence descending and filtered to scores >= 0.3.
    ///
    /// - Parameters:
    ///   - metadata: The program metadata to match against.
    ///   - entries: The game database entries to search.
    /// - Returns: Sorted array of match results above the minimum confidence threshold.
    public static func match(
        metadata: ProgramMetadata,
        against entries: [GameIdentityRecord]
    ) -> [GameIdentityMatch] {
        var results: [GameIdentityMatch] = []

        for (index, entry) in entries.enumerated() {
            if let result = scoreEntry(metadata: metadata, entry: entry, index: index) {
                results.append(result)
            }
        }

        return results.sorted { $0.confidence > $1.confidence }
    }

    /// Returns the single best match if confidence is high enough and unambiguous.
    ///
    /// Returns `nil` if:
    /// - No matches exist above 0.7 confidence
    /// - The top two matches are within 0.1 of each other (ambiguous),
    ///   unless the top match is a hard identifier
    ///
    /// - Parameters:
    ///   - metadata: The program metadata to match against.
    ///   - entries: The game database entries to search.
    /// - Returns: The single best match, or `nil` if ambiguous or below threshold.
    public static func bestMatch(
        metadata: ProgramMetadata,
        against entries: [GameIdentityRecord]
    ) -> GameIdentityMatch? {
        let results = match(metadata: metadata, against: entries)
        guard let top = results.first, top.confidence >= bestMatchMinimum else {
            return nil
        }

        // Hard identifiers always win -- no ambiguity check needed
        if top.tier == .hardIdentifier {
            return top
        }

        // Check for ambiguous close scores
        if results.count >= 2 {
            let second = results[1]
            if top.confidence - second.confidence < ambiguityGap {
                return nil
            }
        }

        return top
    }

    /// Filters entries by tokenized name match against title and aliases.
    ///
    /// Splits the query into tokens and returns entries where any token
    /// matches (case-insensitive prefix) against the entry's title or aliases.
    ///
    /// - Parameters:
    ///   - query: The search string to match.
    ///   - entries: The game database entries to search.
    /// - Returns: Entries matching the query.
    public static func searchEntries(_ query: String, in entries: [GameIdentityRecord]) -> [GameIdentityRecord] {
        let queryTokens = tokenize(query)
        guard !queryTokens.isEmpty else { return [] }

        return entries.filter { entry in
            var searchableTokens = tokenize(entry.title)
            if let aliases = entry.aliases {
                for alias in aliases {
                    searchableTokens.append(contentsOf: tokenize(alias))
                }
            }

            // Return entry if any query token matches any searchable token
            for queryToken in queryTokens {
                for searchToken in searchableTokens where searchToken.hasPrefix(queryToken) {
                    return true
                }
            }
            return false
        }
    }

    // MARK: - Scoring Pipeline

    /// Scores a single entry against the metadata, returning the best tier match.
    private static func scoreEntry(
        metadata: ProgramMetadata,
        entry: GameIdentityRecord, index: Int
    ) -> GameIdentityMatch? {
        // Try tiers in order of confidence: hard > strong > fuzzy
        if let (score, explanation) = scoreHardIdentifiers(metadata: metadata, entry: entry) {
            return GameIdentityMatch(
                index: index, entry: entry,
                confidence: score,
                tier: .hardIdentifier,
                explanation: explanation
            )
        }

        if let (score, explanation) = scoreStrongHeuristics(metadata: metadata, entry: entry) {
            guard score >= minimumThreshold else { return nil }
            return GameIdentityMatch(
                index: index, entry: entry,
                confidence: score,
                tier: .strongHeuristic,
                explanation: explanation
            )
        }

        if let (score, explanation) = scoreFuzzy(metadata: metadata, entry: entry) {
            guard score >= minimumThreshold else { return nil }
            return GameIdentityMatch(
                index: index, entry: entry,
                confidence: score,
                tier: .fuzzy,
                explanation: explanation
            )
        }

        return nil
    }

    // MARK: - Hard Identifiers (0.95-1.0)

    /// Checks Steam App ID and file size + PE timestamp matches.
    private static func scoreHardIdentifiers(
        metadata: ProgramMetadata,
        entry: GameIdentityRecord
    ) -> (Double, String)? {
        // Steam App ID match (highest confidence)
        if let metadataAppId = metadata.steamAppId, let entryAppId = entry.steamAppId, metadataAppId == entryAppId {
            return (1.0, "Steam App ID \(entryAppId) matches exactly")
        }

        // File size + PE timestamp match (0.95)
        if let metaSize = metadata.fileSize, let metaTimestamp = metadata.peTimestamp,
           let fingerprints = entry.exeFingerprints {
            for fingerprint in fingerprints {
                if let fpSize = fingerprint.fileSize, let fpTimestamp = fingerprint.peTimestamp, metaSize == fpSize,
                   abs(metaTimestamp.timeIntervalSince(fpTimestamp)) < 1.0 {
                    return (0.95, "File size and PE timestamp match known fingerprint")
                }
            }
        }

        return nil
    }

    // MARK: - Strong Heuristics (0.7-0.9)

    /// Checks executable name match and path pattern match.
    private static func scoreStrongHeuristics(
        metadata: ProgramMetadata,
        entry: GameIdentityRecord
    ) -> (Double, String)? {
        guard let entryExeNames = entry.exeNames else { return nil }

        let metaExeLower = metadata.exeName.lowercased()

        // Check exact exe name match (case-insensitive)
        let exeMatch = entryExeNames.contains { $0.lowercased() == metaExeLower }
        guard exeMatch else { return nil }

        // Base score for exe name match
        var score = 0.85
        var explanation = "Executable name '\(metadata.exeName)' matches database entry"

        // Bonus for path pattern match
        if let installPath = metadata.installPath, let pathPatterns = entry.pathPatterns {
            let pathLower = installPath.lowercased()
            let pathMatch = pathPatterns.contains { pathLower.contains($0.lowercased()) }
            if pathMatch {
                score = 0.90
                explanation += " with install path confirmation"
            }
        }

        // Apply generic exe penalty
        if genericExeNames.contains(metaExeLower) {
            score += genericPenalty
            explanation += " (generic exe name penalty applied)"
        }

        return (score, explanation)
    }

    // MARK: - Fuzzy Matching (0.3-0.6)

    /// Tokenizes exe name and compares against entry title and aliases.
    private static func scoreFuzzy(
        metadata: ProgramMetadata,
        entry: GameIdentityRecord
    ) -> (Double, String)? {
        // Tokenize the exe name (remove .exe, split on separators)
        let exeTokens = tokenizeExeName(metadata.exeName)
        guard !exeTokens.isEmpty else { return nil }

        // Build target tokens from title + aliases
        var targetTokens = tokenize(entry.title)
        if let aliases = entry.aliases {
            for alias in aliases {
                targetTokens.append(contentsOf: tokenize(alias))
            }
        }
        // Deduplicate target tokens
        let uniqueTargets = Set(targetTokens)

        // Count matching tokens
        let matchCount = exeTokens.filter { exeToken in
            uniqueTargets.contains { $0.hasPrefix(exeToken) || exeToken.hasPrefix($0) }
        }.count

        guard matchCount > 0 else { return nil }

        // Scale to 0.3-0.6 range
        let ratio = Double(matchCount) / Double(exeTokens.count)
        var score = 0.3 + ratio * 0.3

        var explanation = "Name tokens match: \(matchCount)/\(exeTokens.count) tokens"

        // Install path bonus
        if let installPath = metadata.installPath, let pathPatterns = entry.pathPatterns {
            let pathLower = installPath.lowercased()
            let pathMatch = pathPatterns.contains { pathLower.contains($0.lowercased()) }
            if pathMatch {
                score += 0.1
                explanation += " + install path bonus"
            }
        }

        // Cap at 0.69 to stay below strong heuristic tier
        score = min(score, 0.69)

        return (score, explanation)
    }

    // MARK: - Tokenization

    /// Tokenizes a string by splitting on whitespace and common separators.
    private static func tokenize(_ text: String) -> [String] {
        let separators = CharacterSet.alphanumerics.inverted
        return text
            .lowercased()
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
    }

    /// Tokenizes an executable name, removing the .exe extension and splitting.
    private static func tokenizeExeName(_ name: String) -> [String] {
        var cleaned = name.lowercased()
        if cleaned.hasSuffix(".exe") {
            cleaned = String(cleaned.dropLast(4))
        }
        let separators = CharacterSet(charactersIn: "._- ")
        return cleaned
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
    }
}
