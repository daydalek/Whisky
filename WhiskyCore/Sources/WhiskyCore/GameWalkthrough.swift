import Foundation

/// The provider's graph is retained verbatim so new step kinds survive storage and bridge round trips.
public enum WalkthroughValue: Codable, Hashable, Sendable {
    case object([String: WalkthroughValue]), array([WalkthroughValue]), string(String)
    case number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode(Double.self) { self = .number(item) }
        else if let item = try? value.decode([WalkthroughValue].self) { self = .array(item) }
        else { self = try .object(value.decode([String: WalkthroughValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case let .object(item): try value.encode(item)
        case let .array(item): try value.encode(item)
        case let .string(item): try value.encode(item)
        case let .number(item): try value.encode(item)
        case let .bool(item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }
}

public struct GameWalkthrough: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let workID: String
    public let source: String
    public let sourceURL: URL?
    public let sourceAuthor: String?
    public let sourceUpdatedOn: String?
    public let lang: String
    public let release: WalkthroughValue?
    public let characters: [WalkthroughValue]
    public let endingCount: Int
    public let saveCount: Int
    public let segmentCount: Int
    public let workRouteHints: Bool
    public let workContentLimit: String
    public let updatedAt: String
    public var chart: WalkthroughValue?
    public let importReview: WalkthroughValue?

    enum CodingKeys: String, CodingKey {
        case id, source, lang, release, characters, chart
        case workID = "work_id", sourceURL = "source_url", sourceAuthor = "source_author"
        case sourceUpdatedOn = "source_updated_on", endingCount = "ending_count", saveCount = "save_count"
        case segmentCount = "segment_count", workRouteHints = "work_route_hints"
        case workContentLimit = "work_content_limit", updatedAt = "updated_at", importReview = "import_review"
    }
}
