//
//  LibraryMetadataService.swift
//  WhiskyApplication
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
import WhiskyBridgeProtocol
import WhiskyCore
import WhiskyMetadata
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor
public final class LibraryMetadataService {
    public static let methods = [
        "metadata.search", "metadata.sync", "metadata.apply", "metadata.clear",
        "metadata.cover.import", "metadata.cover.reset"
    ]
    private static let searchThumbnailLimit = 8
    let jobs: BridgeJobStore
    let session: URLSession
    let networkAccess: MetadataNetworkAccess

    public init(jobs: BridgeJobStore, session: URLSession = .shared, networkAccess: @escaping MetadataNetworkAccess) {
        self.jobs = jobs
        self.session = session
        self.networkAccess = networkAccess
    }

    /// Metadata operations are addressed by library entry, so the bridge reads
    /// the entry first and then uses its bottle-relative identity for storage.
    /// Network searches run as jobs; local writes answer immediately.
    public func call(
        _ method: String,
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) async throws -> JSONValue {
        if method == "metadata.sync" {
            return try syncMetadata(params: params, workspace: workspace)
        }
        let entry = try await workspace.entry(params)
        let store = GameMetadataStore(directory: entry.metadataDirectory, networkAccess: networkAccess)
        switch method {
        case "metadata.search":
            return try search(params: params, store: store)
        case "metadata.apply": return try await apply(params: params, entry: entry, store: store)
        case "metadata.clear":
            try await store.remove(for: entry.metadataIdentity)
            return .object(["cleared": .bool(true)])
        case "metadata.cover.import": return try await importCover(params: params, entry: entry, store: store)
        case "metadata.cover.reset":
            var settings = try await store.loadCoverSettings(for: entry.metadataIdentity)
            settings.useCustomCover = false
            try await store.saveCoverSettings(settings, for: entry.metadataIdentity)
            return .object(["cover": .string("")])
        default:
            throw BridgeFailure("method_unavailable", "Native method is unavailable")
        }
    }

    private func apply(
        params: [String: JSONValue], entry: LibraryEntry, store: GameMetadataStore
    ) async throws -> JSONValue {
        let session = self.session
        guard let value = params["metadata"] else {
            throw BridgeFailure("invalid_params", "Missing metadata snapshot")
        }
        var metadata = try value.decoded(GameMetadata.self)
        if metadata.source == .steam {
            // Search only returns identity and thumbnails for Steam.
            metadata = try await PublicGameMetadataProvider(
                source: .steam,
                session: session,
                networkAccess: networkAccess
            ).details(for: metadata)
        }
        try await store.save(metadata, for: entry.metadataIdentity)
        if let cover = metadata.coverURL {
            try? await store.cacheCover(from: cover, session: session)
        }
        return try .object([
            "metadata": .encoded(metadata),
            "cover": .string(
                metadata.coverURL.flatMap { store.cachedCoverURL(for: $0)?.path } ?? ""
            )
        ])
    }

    private func importCover(
        params: [String: JSONValue], entry: LibraryEntry, store: GameMetadataStore
    ) async throws -> JSONValue {
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
    }

    private func search(params: [String: JSONValue], store: GameMetadataStore) throws -> JSONValue {
        let session = self.session
        let query = try params.text("query").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw BridgeFailure("invalid_params", "Search text is required") }
        let sources = Self.requestedSources(params)
        let providers = sources.filter { $0 != .hikarinagi }
            .map { PublicGameMetadataProvider(source: $0, session: session, networkAccess: networkAccess) }
        return try jobs.start(name: "metadata.search") { progress in
            progress(.object(["stage": .string("searching")]))
            let results = await GameMetadataSearch.search(query, providers: providers)
            return try await .object([
                "results": .array(results.concurrentMap { result in
                    try await .object([
                        "source": .string(result.source.rawValue),
                        "error": result.error.map(JSONValue.string) ?? .null,
                        // Cache thumbnails for the first hits so the
                        // frontend can render picture rows without a
                        // second round-trip; failures leave the field
                        // empty and the row renders a placeholder.
                        "games": .array(result.games
                            .prefix(Self.searchThumbnailLimit)
                            .concurrentMap { game in
                                var object = try JSONValue.encoded(game).object ?? [:]
                                if let remote = game.thumbnailURL ?? game.coverURL {
                                    try? await store.cacheCover(from: remote, session: session)
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
    }

    /// The scraper sources named by the caller, or all of them when the
    /// parameter is absent or names no known source.
    static func requestedSources(_ params: [String: JSONValue]) -> [GameMetadataSource] {
        if case let .array(items)? = params["sources"] {
            let chosen = items.compactMap { $0.string.flatMap(GameMetadataSource.init(rawValue:)) }
            if !chosen.isEmpty {
                return chosen
            }
        }
        return GameMetadataSource.allCases
    }
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
            return try results.map { value in
                guard let value else { throw BridgeFailure("operation_failed", "Missing thumbnail result") }
                return value
            }
        }
    }
}
