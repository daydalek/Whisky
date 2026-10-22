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
    /// Metadata operations are addressed by library entry, so the bridge reads
    /// the entry first and then uses its bottle-relative identity for storage.
    /// Network searches run as jobs; local writes answer immediately.
    func metadataCall(
        _ method: String,
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) async throws -> JSONValue {
        if method == "gameConfig.match" || method == "gameConfig.apply" {
            return try await gameConfigCall(method, params: params, workspace: workspace)
        }
        if method == "metadata.sync" {
            return try syncMetadata(params: params, workspace: workspace)
        }
        let entry = try await workspace.entry(params)
        let store = GameMetadataStore(directory: entry.metadataDirectory)
        switch method {
        case "metadata.search":
            let query = try params.text("query").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { throw BridgeFailure("invalid_params", "Search text is required") }
            let sources = Self.requestedSources(params)
            let providers = sources.filter { $0 != .hikarinagi }
                .map { PublicGameMetadataProvider(source: $0) }
            return try jobs.start(name: "metadata.search") { progress in
                progress(.object(["stage": .string("searching")]))
                let results = await GameMetadataSearch.search(query, providers: providers)
                return .object([
                    "results": .array(try await results.concurrentMap { result in
                        .object([
                            "source": .string(result.source.rawValue),
                            "error": result.error.map(JSONValue.string) ?? .null,
                            // Cache thumbnails for the first hits so the
                            // frontend can render picture rows without a
                            // second round-trip; failures leave the field
                            // empty and the row renders a placeholder.
                            "games": .array(try await result.games
                                .prefix(Self.searchThumbnailLimit)
                                .concurrentMap { game in
                                    var object = try JSONValue.encoded(game).object ?? [:]
                                    if let remote = game.thumbnailURL ?? game.coverURL {
                                        try? await store.cacheCover(from: remote)
                                        if let local = store.cachedCoverURL(for: remote) {
                                            object["thumbnail"] = .string(local.path)
                                        }
                                    }
                                    return .object(object)
                                })
                        ])
                    })
                ])
            }
        case "metadata.apply":
            guard let value = params["metadata"] else {
                throw BridgeFailure("invalid_params", "Missing metadata snapshot")
            }
            var metadata = try value.decoded(GameMetadata.self)
            if metadata.source == .steam {
                // Search only returns identity and thumbnails for Steam.
                metadata = try await PublicGameMetadataProvider(source: .steam).details(for: metadata)
            }
            try await store.save(metadata, for: entry.metadataIdentity)
            if let cover = metadata.coverURL {
                try? await store.cacheCover(from: cover)
            }
            return .object([
                "metadata": try .encoded(metadata),
                "cover": .string(
                    metadata.coverURL.flatMap { store.cachedCoverURL(for: $0)?.path } ?? ""
                )
            ])
        case "metadata.clear":
            try await store.remove(for: entry.metadataIdentity)
            return .object(["cleared": .bool(true)])
        case "metadata.cover.import":
            let path = try params.path("path")
            let size = try path.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 30 * 1_024 * 1_024 else {
                throw BridgeFailure("invalid_params", "Cover image must be at most 30 MiB")
            }
            let data = try Data(contentsOf: path)
            let settings = try await store.importCover(data, for: entry.metadataIdentity)
            guard let cover = store.customCoverURL(for: settings) else {
                throw BridgeFailure("operation_failed", "Could not store the cover image")
            }
            return .object(["cover": .string(cover.path)])
        case "metadata.cover.reset":
            var settings = try await store.loadCoverSettings(for: entry.metadataIdentity)
            settings.useCustomCover = false
            try await store.saveCoverSettings(settings, for: entry.metadataIdentity)
            return .object(["cover": .string("")])
        default:
            throw BridgeFailure("method_unavailable", "Native method is unavailable")
        }
    }

    /// The scraper sources named by the caller, or all of them when the
    /// parameter is absent or names no known source.
    static func requestedSources(_ params: [String: JSONValue]) -> [GameMetadataSource] {
        if case let .array(items)? = params["sources"] {
            let chosen = items.compactMap { $0.string.flatMap(GameMetadataSource.init(rawValue:)) }
            if !chosen.isEmpty { return chosen }
        }
        return GameMetadataSource.allCases
    }

    /// Automatic matching for every folder entry that has no metadata yet.
    /// The manual "scan and sync game info" action passes `automatic: false`
    /// and keeps its "everything missing" meaning; `automatic: true` honours
    /// the folder library's own switch and only touches entries still pending
    /// their initial match, retiring the marker once providers answered
    /// (`LibraryView.loadMetadata`).
    private func syncMetadata(
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) throws -> JSONValue {
        let container = try workspace.resolve(params)
        let sources = Self.requestedSources(params).filter { $0 != .hikarinagi }
        let providers = sources.map { PublicGameMetadataProvider(source: $0) }
        let automatic = params["automatic"]?.bool ?? false
        return try jobs.start(name: "metadata.sync") { progress in
            let entries = try await workspace.entries(in: container)
            let visibility = try? LibraryVisibility.load(bottleURL: container)
            var library = automatic ? try? FolderGameLibrary.load(bottleURL: container) : nil
            var matched = 0
            var failed = 0
            var scanned = 0
            for (index, candidateEntry) in entries.enumerated() {
                try Task.checkCancellation()
                guard candidateEntry.source == .folder else { continue }
                scanned += 1
                let candidateStore = GameMetadataStore(directory: candidateEntry.metadataDirectory)
                let folderKey: String? = if automatic,
                    case let .program(folder) = candidateEntry.launch {
                    FolderGameLibrary.key(for: folder, bottleURL: container)
                } else {
                    nil
                }
                if automatic {
                    guard library?.automaticMetadata == true,
                          folderKey.flatMap({ library?.pendingMetadata.contains($0) }) == true
                    else { continue }
                }
                let hasMetadata = (try? await candidateStore.load(
                    for: candidateEntry.metadataIdentity
                )) != nil
                if automatic {
                    if hasMetadata {
                        // Matched earlier by another route; retire the marker.
                        if let folderKey {
                            library?.pendingMetadata.remove(folderKey)
                        }
                        continue
                    }
                } else if hasMetadata {
                    continue
                }
                guard (try? await candidateStore.allowsAutomaticMatch(
                    for: candidateEntry.metadataIdentity
                )) == true
                else { continue }
                var freshRecord: JSONValue?
                let outcome = await GameMetadataSearch.automaticMatch(
                    FolderGameMatching.query(candidateEntry.name),
                    providers: providers
                )
                if let candidate = outcome.candidate {
                    do {
                        let details = try await PublicGameMetadataProvider(source: candidate.source)
                            .details(for: candidate)
                            .usingLibraryTitle(candidateEntry.name)
                        try await candidateStore.saveAutomatic(
                            details,
                            for: candidateEntry.metadataIdentity
                        )
                        if let cover = details.coverURL {
                            try? await candidateStore.cacheCover(from: cover)
                        }
                        matched += 1
                        // Frontends patch the finished card from the progress
                        // payload, so a match has to carry its own record.
                        if let visibility,
                           let record = try? EntryRecord(candidateEntry, visibility: visibility) {
                            freshRecord = try? .encoded(record)
                        }
                    } catch {
                        failed += 1
                    }
                }
                if automatic,
                   let folderKey,
                   !outcome.allProvidersFailed {
                    // Providers answered; the initial match is complete even
                    // without a candidate, so do not retry on the next pass.
                    library?.pendingMetadata.remove(folderKey)
                }
                var payload: [String: JSONValue] = [
                    "stage": .string("syncing"),
                    "scanned": .integer(Int64(index + 1)),
                    "matched": .integer(Int64(matched)),
                    "failed": .integer(Int64(failed))
                ]
                if freshRecord != nil {
                    payload["entryID"] = .string(candidateEntry.id)
                    payload["entry"] = freshRecord
                }
                progress(.object(payload))
            }
            if automatic {
                try? library?.save(bottleURL: container)
            }
            return .object([
                "matched": .integer(Int64(matched)),
                "failed": .integer(Int64(failed)),
                "scanned": .integer(Int64(scanned))
            ])
        }
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

extension MacOSApplicationServices {
    /// Only the first hits of a search get thumbnails; the rest stay text
    /// rows, keeping the job quick and the list cheap to render.
    static let searchThumbnailLimit = 8
}

extension Sequence {
    /// Order-preserving concurrent map for the small thumbnail fetches in
    /// `metadata.search`; one slow provider must not serialize the rest.
    func concurrentMap<T: Sendable>(
        _ transform: @escaping @Sendable (Element) async throws -> T
    ) async throws -> [T] where Element: Sendable {
        let elements = Array(self)
        return try await withThrowingTaskGroup(of: (Int, T).self) { group in
            for (index, element) in elements.enumerated() {
                group.addTask { try await (index, transform(element)) }
            }
            var results = [T?](repeating: nil, count: elements.count)
            for try await (index, value) in group {
                results[index] = value
            }
            return results.map { $0! }
        }
    }
}
