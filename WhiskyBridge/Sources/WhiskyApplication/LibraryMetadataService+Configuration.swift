import Foundation
import WhiskyBridgeProtocol
import WhiskyCore
import WhiskyMetadata

extension LibraryMetadataService {
    func configuration(
        _ method: String, params: [String: JSONValue], entry: LibraryEntry, store: GameMetadataStore
    ) async throws -> JSONValue {
        let existing = try await store.loadRecord(for: entry.metadataIdentity)
        var record = try existing ?? defaultRecord()
        var errors: [String: JSONValue] = [:]
        if method == "metadata.configuration.save" {
            guard let value = params["record"] else {
                throw BridgeFailure("invalid_params", "Missing metadata record")
            }
            let draft = try value.decoded(GameMetadataRecord.self)
            try validate(draft)
            record = draft
            // Re-selecting the same work must not downgrade a fetched snapshot
            // to the abbreviated search result sent by the editor.
            if let existing {
                for (source, snapshot) in existing.snapshots
                    where existing.bindings[source] == snapshot.sourceID
                        && record.bindings[source] == snapshot.sourceID {
                    record.snapshots[source] = snapshot
                }
            }
            record.snapshots = record.snapshots.filter {
                $0.key == $0.value.source.rawValue && record.bindings[$0.key] == $0.value.sourceID
            }
            var hydratedCovers: [URL] = []
            if params["hydrate"]?.bool == true {
                // Stage all fetches before the single commit. A failed provider
                // leaves the saved record untouched and the editor's draft intact.
                let allowed = try enabledSources(params)
                for source in allowed {
                    let key = source.rawValue
                    guard let id = record.bindings[key] else { continue }
                    let previous = existing?.snapshots[key]
                    let unchanged = existing?.bindings[key] == id
                        && previous?.sourceID == id && previous?.source == source
                    guard !unchanged else { continue }
                    let snapshot = try await PublicGameMetadataProvider(
                        source: source, session: session, networkAccess: networkAccess
                    ).refresh(sourceID: id)
                    guard snapshot.sourceID == id else { throw URLError(.badServerResponse) }
                    record.snapshots[key] = snapshot
                    if let cover = snapshot.coverURL { hydratedCovers.append(cover) }
                }
            }
            try Task.checkCancellation()
            try await store.saveRecord(record, for: entry.metadataIdentity)
            for cover in hydratedCovers {
                try? await store.cacheCover(from: cover, session: session)
            }
        } else if method == "metadata.refresh" {
            for source in Self.requestedSources(params) {
                guard let id = record.bindings[source.rawValue] else { continue }
                do {
                    let snapshot = try await PublicGameMetadataProvider(
                        source: source, session: session, networkAccess: networkAccess
                    ).refresh(sourceID: id)
                    guard snapshot.sourceID == id else { throw URLError(.badServerResponse) }
                    // Re-read after network suspension: don't resurrect an old binding
                    // or overwrite another editor's manual changes.
                    guard try await store.updateSnapshot(snapshot, for: entry.metadataIdentity) else { continue }
                    if let cover = snapshot.coverURL { try? await store.cacheCover(from: cover, session: session) }
                } catch {
                    errors[source.rawValue] = .string(error.localizedDescription)
                }
            }
            record = try await store.loadRecord(for: entry.metadataIdentity) ?? record
        }
        return try .object([
            "hasRecord": .bool(method == "metadata.configuration.save" || existing != nil),
            "record": .encoded(record),
            "resolved": .encoded(record.resolved()),
            "errors": .object(errors),
            "capabilities": .object(Dictionary(uniqueKeysWithValues: GameMetadataSource.allCases.map {
                ($0.rawValue, .object([
                    "refresh": .bool($0 != .hikarinagi),
                    "characters": .bool($0 == .bangumi || $0 == .vndb)
                ]))
            }))
        ])
    }

    private func validate(_ record: GameMetadataRecord) throws {
        let categories: Set<String> = ["basic", "summary", "cover", "characters"]
        guard record.version == 1, record.defaultSource != .hikarinagi,
              Set(record.categorySources.keys).isSubset(of: categories),
              !record.categorySources.values.contains(.hikarinagi) else {
            throw BridgeFailure("invalid_params", "Unsupported metadata strategy")
        }
        for (key, id) in record.bindings {
            guard let source = GameMetadataSource(rawValue: key), source != .hikarinagi else {
                throw BridgeFailure("invalid_params", "Unsupported binding source")
            }
            let pattern = source == .vndb ? #"^v[1-9][0-9]*$"# : #"^[1-9][0-9]*$"#
            guard id.range(of: pattern, options: .regularExpression) != nil else {
                throw BridgeFailure("invalid_params", "Invalid \(key) identity")
            }
        }
    }

    func defaultRecord() throws -> GameMetadataRecord {
        let values = try preferences?.call("preferences.read", params: [:]).object ?? [:]
        var record = GameMetadataRecord(defaultSource:
            values["libraryMetadataDefaultSource"]?.string.flatMap(GameMetadataSource.init(rawValue:)) ?? .bangumi)
        for category in ["basic", "summary", "cover", "characters"] {
            let key = "libraryMetadata" + category.prefix(1).uppercased() + category.dropFirst() + "Source"
            if let value = values[key]?.string.flatMap(GameMetadataSource.init(rawValue:)) {
                record.categorySources[category] = value
            }
        }
        return record
    }
}
