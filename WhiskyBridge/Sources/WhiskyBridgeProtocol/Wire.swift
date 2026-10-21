//
//  Wire.swift
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

/// Paths are absolute native path strings. Dates are Unix seconds. Binary data is base64.
/// Integer request IDs are strings on the wire, preserving all 64 bits in every frontend.
public enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), integer(Int64), number(Double), string(String)
    case array([JSONValue]), object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let boolean = try? value.decode(Bool.self) {
            self = .bool(boolean)
        } else if let integer = try? value.decode(Int64.self) {
            self = .integer(integer)
        } else if let number = try? value.decode(Double.self), number.isFinite {
            self = .number(number)
        } else if let string = try? value.decode(String.self) {
            self = .string(string)
        } else if let array = try? value.decode([JSONValue].self) {
            self = .array(array)
        } else {
            self = try .object(value.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case let .bool(boolean): try value.encode(boolean)
        case let .integer(integer): try value.encode(integer)
        case let .number(number): try value.encode(number)
        case let .string(string): try value.encode(string)
        case let .array(array): try value.encode(array)
        case let .object(object): try value.encode(object)
        }
    }

    public static func encoded(_ value: some Encodable) throws -> Self {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try JSONDecoder().decode(Self.self, from: encoder.encode(value))
    }

    public func decoded<T: Decodable>(_ type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: JSONEncoder().encode(self))
    }

    public var string: String? {
        if case let .string(string) = self {
            string
        } else {
            nil
        }
    }

    public var object: [String: Self]? {
        if case let .object(object) = self {
            object
        } else {
            nil
        }
    }

    public var bool: Bool? {
        if case let .bool(boolean) = self {
            boolean
        } else {
            nil
        }
    }

    public var integer: Int64? {
        if case let .integer(integer) = self {
            integer
        } else {
            nil
        }
    }
}

public struct BridgeRequest: Codable, Sendable {
    public static let version = 1
    public let version: Int
    public let id: String
    public let method: String
    public let params: [String: JSONValue]
    public init(id: String, method: String, params: [String: JSONValue] = [:], version: Int = Self.version) {
        self.version = version
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct BridgeFailure: Error, Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let retryable: Bool
    public init(_ code: String, _ message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}

public struct BridgeResponse: Codable, Sendable {
    public let version: Int
    public let id: String?
    public let result: JSONValue?
    public let error: BridgeFailure?
    public init(id: String?, result: JSONValue) {
        version = BridgeRequest.version
        self.id = id
        self.result = result
        error = nil
    }

    public init(id: String?, error: BridgeFailure) {
        version = BridgeRequest.version
        self.id = id
        result = nil
        self.error = error
    }
}

/// Bounded NDJSON framing accepts fragmented UTF-8 and CRLF. A broken frame is terminal.
public struct BridgeFramer: Sendable {
    public static let maximumFrameBytes = 1_024 * 1_024
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> [Data] {
        var frames: [Data] = []
        for byte in data {
            if byte == 10 {
                if buffer.last == 13 {
                    buffer.removeLast()
                }
                if !buffer.isEmpty {
                    frames.append(buffer)
                }
                buffer.removeAll(keepingCapacity: true)
            } else {
                guard buffer.count < Self.maximumFrameBytes else { throw BridgeFailure(
                    "frame_too_large",
                    "Input frame exceeds 1 MiB"
                ) }
                buffer.append(byte)
            }
        }
        return frames
    }

    public func finish() throws {
        guard buffer.isEmpty else { throw BridgeFailure("truncated_frame", "Input ended before a newline") }
    }
}

public extension [String: JSONValue] {
    func text(_ key: String) throws -> String {
        guard let text = self[key]?.string, !text.isEmpty, !text.contains("\0") else {
            throw BridgeFailure("invalid_params", "Expected a nonempty string: \(key)")
        }
        return text
    }

    func flag(_ key: String) throws -> Bool {
        guard let flag = self[key]?.bool else { throw BridgeFailure("invalid_params", "Expected boolean: \(key)") }
        return flag
    }

    func path(_ key: String) throws -> URL {
        let path = try text(key)
        guard path.hasPrefix("/")
        else { throw BridgeFailure("invalid_params", "Expected absolute native path: \(key)") }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
}
