//
//  LibraryMetadataService+Sync.swift
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

extension LibraryMetadataService {
    // Automatic matching for every folder entry that has no metadata yet.
    // The manual "scan and sync game info" action passes `automatic: false`
    // and keeps its "everything missing" meaning; `automatic: true` honours
    // the folder library's own switch and only touches entries still pending
    // their initial match, retiring the marker once providers answered
    // (`LibraryView.loadMetadata`).
    // The retained job owns the scan counters and pending-marker commit.
    func syncMetadata(
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) throws -> JSONValue {
        let container = try workspace.resolve(params)
        let preferred = try defaultRecord().defaultSource
        let enabled = try enabledSources(params).filter { $0 != .hikarinagi }
        let sources = enabled.filter { $0 == preferred } + enabled.filter { $0 != preferred }
        let providers = sources.map { PublicGameMetadataProvider(
            source: $0,
            session: session,
            networkAccess: networkAccess
        ) }
        let automatic = params["automatic"]?.bool ?? false
        return try jobs.start(name: "metadata.sync") { [self] progress in
            guard !providers.isEmpty else {
                return .object(["matched": .integer(0), "failed": .integer(0), "scanned": .integer(0)])
            }
            let entries = try await workspace.entries(in: container)
            let visibility = try? LibraryVisibility.load(bottleURL: container)
            let library = automatic ? try? FolderGameLibrary.load(bottleURL: container) : nil
            var completedKeys: Set<String> = []
            var matched = 0
            var failed = 0
            var scanned = 0
            for (index, candidateEntry) in entries.enumerated() {
                try Task.checkCancellation()
                guard candidateEntry.source == .folder else { continue }
                scanned += 1
                let candidateStore = GameMetadataStore(
                    directory: candidateEntry.metadataDirectory,
                    networkAccess: networkAccess
                )
                let folderKey: String? = if automatic,
                                            case let .program(folder) = candidateEntry.launch {
                    FolderGameLibrary.key(for: folder, bottleURL: container)
                } else {
                    nil
                }
                if automatic, !Self.isPending(folderKey, in: library) {
                    continue
                }
                let hasMetadata = await (try? candidateStore.load(
                    for: candidateEntry.metadataIdentity
                )) != nil
                if hasMetadata {
                    if automatic, let folderKey {
                        completedKeys.insert(folderKey)
                    }
                    continue
                }
                guard await (try? candidateStore.allowsAutomaticMatch(
                    for: candidateEntry.metadataIdentity
                )) == true
                else { continue }
                let outcome = await match(
                    candidateEntry,
                    providers: providers,
                    store: candidateStore,
                    visibility: visibility
                )
                matched += outcome.matched
                failed += outcome.failed
                let freshRecord = outcome.record
                if automatic,
                   let folderKey,
                   !outcome.allProvidersFailed {
                    // Providers answered; the initial match is complete even
                    // without a candidate, so do not retry on the next pass.
                    completedKeys.insert(folderKey)
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
                try Self.retire(completedKeys, in: container)
            }
            return .object([
                "matched": .integer(Int64(matched)),
                "failed": .integer(Int64(failed)),
                "scanned": .integer(Int64(scanned))
            ])
        }
    }

    private struct MatchResult {
        let matched: Int
        let failed: Int
        let record: JSONValue?
        let allProvidersFailed: Bool
    }

    private func match(
        _ entry: LibraryEntry, providers: [PublicGameMetadataProvider], store: GameMetadataStore,
        visibility: LibraryVisibility?
    ) async -> MatchResult {
        let outcome = await GameMetadataSearch.automaticMatch(
            FolderGameMatching.query(entry.name),
            providers: providers
        )
        guard let candidate = outcome.candidate else { return MatchResult(
            matched: 0,
            failed: 0,
            record: nil,
            allProvidersFailed: outcome.allProvidersFailed
        ) }
        do {
            let details = try await PublicGameMetadataProvider(
                source: candidate.source, session: session, networkAccess: networkAccess
            ).details(for: candidate)
            var metadataRecord = try defaultRecord()
            metadataRecord.defaultSource = details.source
            metadataRecord.bindings[details.source.rawValue] = details.sourceID
            metadataRecord.snapshots[details.source.rawValue] = details
            let display = details.usingLibraryTitle(entry.name)
            if display.title != details.title {
                metadataRecord.manualTitle = display.title
            }
            try await store.saveAutomaticRecord(metadataRecord, for: entry.metadataIdentity)
            if let cover = details.coverURL {
                try? await store.cacheCover(from: cover, session: session)
            }
            let record = visibility.flatMap { try? EntryRecord(entry, visibility: $0) }
            return MatchResult(
                matched: 1,
                failed: 0,
                record: record.flatMap { try? .encoded($0) },
                allProvidersFailed: outcome.allProvidersFailed
            )
        } catch {
            return MatchResult(matched: 0, failed: 1, record: nil, allProvidersFailed: outcome.allProvidersFailed)
        }
    }

    private static func isPending(_ key: String?, in library: FolderGameLibrary?) -> Bool {
        library?.automaticMetadata == true && key.flatMap { library?.pendingMetadata.contains($0) } == true
    }

    private static func retire(_ completedKeys: Set<String>, in container: URL) throws {
        guard !completedKeys.isEmpty else { return }
        let url = container.appendingPathComponent("Folder Games.json")
        try HostFileLock().withExclusiveLock(at: url.appendingPathExtension("lock")) {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            guard var current = try JSONSerialization.jsonObject(with: ApplicationWorkspace.read(url))
                as? [String: Any], let pending = current["pendingMetadata"] as? [String]
            else { throw BridgeFailure("invalid_settings", "Folder metadata queue is unreadable") }
            current["pendingMetadata"] = pending.filter { !completedKeys.contains($0) }
            try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys])
                .write(to: url, options: .atomic)
        }
    }
}
