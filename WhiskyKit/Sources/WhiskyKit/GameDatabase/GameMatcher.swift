//
//  GameMatcher.swift
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
import WhiskyCore

public typealias ProgramMetadata = WhiskyCore.ProgramMetadata

/// Native result/variant adapter over the shared identity scoring engine.
public enum GameMatcher {
    public static func match(metadata: ProgramMetadata, against entries: [GameDBEntry]) -> [MatchResult] {
        GameIdentityMatcher.match(metadata: metadata, against: entries.map(identity)).map { score in
            result(score, entries: entries)
        }
    }

    public static func bestMatch(metadata: ProgramMetadata, against entries: [GameDBEntry]) -> MatchResult? {
        GameIdentityMatcher.bestMatch(metadata: metadata, against: entries.map(identity)).map { score in
            result(score, entries: entries)
        }
    }

    public static func searchEntries(_ query: String, in entries: [GameDBEntry]) -> [GameDBEntry] {
        let matches = GameIdentityMatcher.searchEntries(query, in: entries.map(identity))
        return entries.filter { matches.contains(identity($0)) }
    }

    private static func identity(_ entry: GameDBEntry) -> GameIdentityRecord {
        GameIdentityRecord(
            id: entry.id,
            title: entry.title,
            aliases: entry.aliases,
            steamAppId: entry.steamAppId,
            exeNames: entry.exeNames,
            exeFingerprints: entry.exeFingerprints,
            pathPatterns: entry.pathPatterns
        )
    }

    private static func result(_ score: GameIdentityMatch, entries: [GameDBEntry]) -> MatchResult {
        let entry = entries[score.index]
        return MatchResult(
            entry: entry,
            confidence: score.confidence,
            tier: score.tier,
            explanation: score.explanation,
            recommendedVariant: selectVariant(from: entry)
        )
    }

    /// Selects the recommended variant for the current machine.
    private static func selectVariant(from entry: GameDBEntry) -> GameConfigVariant? {
        guard !entry.variants.isEmpty else { return nil }

        let currentArch = machineArchitecture()

        // Filter variants whose constraints match current machine
        // Sort variants: prefer those tested on current architecture
        let matching = entry.variants.sorted { lhs, rhs in
            let lhsMatchesArch = lhs.testedWith?.cpuArchitecture == currentArch
            let rhsMatchesArch = rhs.testedWith?.cpuArchitecture == currentArch
            if lhsMatchesArch != rhsMatchesArch {
                return lhsMatchesArch
            }
            return false
        }

        // Prefer isDefault variant
        if let defaultVariant = matching.first(where: { $0.isDefault == true }) {
            return defaultVariant
        }

        return matching.first ?? entry.variants.first
    }

    /// Returns the current machine's CPU architecture string.
    private static func machineArchitecture() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}
