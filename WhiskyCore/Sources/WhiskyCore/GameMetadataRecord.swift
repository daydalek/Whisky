import Foundation

public struct MetadataProvenance: Codable, Hashable, Sendable {
    public var source: GameMetadataSource?
    public var sourceID: String?
    public var manual: Bool?
}

public struct ResolvedGameMetadata: Codable, Sendable {
    public var metadata: GameMetadata?
    public var provenance: [String: MetadataProvenance]
}

/// Only explicitly bound identities participate in resolution. Missing data never
/// silently falls back to a different provider.
public struct GameMetadataRecord: Codable, Sendable {
    public var version = 1
    public var defaultSource: GameMetadataSource = .bangumi
    public var categorySources: [String: GameMetadataSource] = [:]
    public var bindings: [String: String] = [:]
    public var snapshots: [String: GameMetadata] = [:]
    public var manualTitle: String?
    public var manualSummary: String?

    public init(defaultSource: GameMetadataSource = .bangumi) {
        self.defaultSource = defaultSource
    }

    public init(legacy: GameMetadata) {
        defaultSource = legacy.source
        bindings = [legacy.source.rawValue: legacy.sourceID]
        snapshots = [legacy.source.rawValue: legacy]
        // Older automatic matching replaced VNDB's display title with the local
        // Chinese folder name, retaining the remote names in alternateTitles.
        // Preserve that detectable substitution outside the refreshable snapshot.
        if legacy.source == .vndb,
           let language = legacy.titleLanguage, !language.hasPrefix("zh"),
           let remoteNames = legacy.alternateTitles, !remoteNames.isEmpty,
           !remoteNames.contains(legacy.title), legacy.title != legacy.originalTitle,
           legacy.title.unicodeScalars.contains(where: { (0x3400 ... 0x9FFF).contains($0.value) }),
           !legacy.title.unicodeScalars.contains(where: {
               (0x3040 ... 0x30FF).contains($0.value) && $0.value != 0x30FB
           }) {
            manualTitle = legacy.title
        }
    }

    public static func decode(_ data: Data) throws -> GameMetadataRecord {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if object?["version"] != nil {
            let record = try JSONDecoder().decode(Self.self, from: data)
            guard record.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            return record
        }
        return try GameMetadataRecord(legacy: JSONDecoder().decode(GameMetadata.self, from: data))
    }

    public func snapshot(for category: String) -> GameMetadata? {
        let key = (categorySources[category] ?? defaultSource).rawValue
        guard let snapshot = snapshots[key], snapshot.source.rawValue == key,
              bindings[key] == snapshot.sourceID else { return nil }
        return snapshot
    }

    public func resolved() -> ResolvedGameMetadata {
        var provenance: [String: MetadataProvenance] = [:]
        for category in ["basic", "summary", "cover", "characters"] {
            if let snapshot = snapshot(for: category) {
                if category == "characters" && snapshot.characters == nil { continue }
                provenance[category] = MetadataProvenance(source: snapshot.source, sourceID: snapshot.sourceID)
            }
        }
        provenance["title"] = provenance["basic"]
        // A missing basic binding must not borrow identity from an unrelated source.
        var metadata = snapshot(for: "basic")
        if metadata != nil {
            metadata?.summary = snapshot(for: "summary")?.summary ?? ""
            metadata?.coverURL = snapshot(for: "cover")?.coverURL
            metadata?.thumbnailURL = snapshot(for: "cover")?.thumbnailURL
            metadata?.characters = snapshot(for: "characters")?.characters
        }
        if let manualTitle {
            metadata?.title = manualTitle
            provenance["title"] = MetadataProvenance(manual: true)
        }
        if let manualSummary {
            metadata?.summary = manualSummary
            provenance["summary"] = MetadataProvenance(manual: true)
        }
        metadata?.provenance = provenance
        return ResolvedGameMetadata(metadata: metadata, provenance: provenance)
    }
}
