//
//  MacOSApplicationServices+Metadata.swift
//  WhiskyNativeBridge
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
import WhiskyApplication
import WhiskyBridgeProtocol
import WhiskyCore
import WhiskyKit

// MARK: - Library metadata, covers, and GameDB recommendations

extension MacOSApplicationServices {
    func metadataCall(
        _ method: String, params: [String: JSONValue], workspace: ApplicationWorkspace
    ) async throws -> JSONValue {
        if method == "gameConfig.match" || method == "gameConfig.apply" {
            return try await gameConfigCall(method, params: params, workspace: workspace)
        }
        return try await LibraryMetadataService(jobs: jobs, networkAccess: {
            try NetworkSettings.requireNetwork()
        }).call(method, params: params, workspace: workspace)
    }

    private func gameConfigCall(
        _ method: String,
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) async throws -> JSONValue {
        let entry = try await workspace.entry(params)
        let container = try workspace.resolve(params)
        guard let bottle = bottle(container) else {
            throw BridgeFailure("invalid_container", "Wine settings are unreadable")
        }
        let executable: URL? = if case let .program(url) = entry.launch { url } else { nil }
        let steamAppID: Int? = if case let .steam(appID) = entry.launch { appID } else { nil }
        let entries = GameDBLoader.loadDefaults()

        if method == "gameConfig.match" {
            let size = executable.flatMap {
                try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize
            }.map(Int64.init)
            let metadata = ProgramMetadata(
                exeName: executable?.lastPathComponent ?? entry.name,
                exeURL: executable,
                fileSize: size,
                steamAppId: steamAppID,
                installPath: executable?.deletingLastPathComponent().path
            )
            let matches = GameMatcher.match(metadata: metadata, against: entries).prefix(3)
            return .object([
                "matches": .array(matches.map { match in
                    let variant = match.recommendedVariant ?? match.entry.defaultVariant
                    let changes = variant.map {
                        GameConfigApplicator.previewChanges(variant: $0, bottle: bottle)
                    } ?? []
                    return .object([
                        "entry": (try? .encoded(match.entry)) ?? .null,
                        "confidence": .number(match.confidence),
                        "explanation": .string(match.explanation),
                        "variantID": .string(variant?.id ?? ""),
                        "changes": .array(changes.map(Self.encodeChange))
                    ])
                })
            ])
        }

        let gameID = try params.text("gameID")
        guard let game = entries.first(where: { $0.id == gameID }) else {
            throw BridgeFailure("unknown_entry", "The GameDB entry is unavailable")
        }
        let variantID = params["variantID"]?.string
        guard let variant = variantID.flatMap({ id in game.variants.first { $0.id == id } })
            ?? game.defaultVariant
        else {
            throw BridgeFailure("invalid_params", "The GameDB entry has no variants")
        }
        let changes = GameConfigApplicator.previewChanges(variant: variant, bottle: bottle)
        _ = try GameConfigApplicator.apply(
            entry: game,
            variant: variant,
            to: bottle,
            programURL: executable
        )
        bottles[container] = nil
        return .object([
            "applied": .bool(true),
            "variantID": .string(variant.id),
            "pendingVerbs": .array((variant.winetricksVerbs ?? []).map { .string($0) }),
            "changes": .array(changes.map(Self.encodeChange))
        ])
    }

    private static func encodeChange(_ change: ConfigChange) -> JSONValue {
        .object([
            "category": .string(change.category),
            "setting": .string(change.settingName),
            "current": .string(change.currentValue),
            "next": .string(change.newValue),
            "highImpact": .bool(change.isHighImpact)
        ])
    }
}
