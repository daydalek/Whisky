//
//  VDFParser.swift
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

/// A value in a parsed Valve Data Format (VDF) document: either a string or a
/// nested key-value object.
public enum VDFValue: Equatable, Sendable {
    case string(String)
    indirect case object([String: VDFValue])

    /// The string content, or `nil` for objects.
    public var stringValue: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
    }

    /// The nested object, or `nil` for strings.
    public var objectValue: [String: VDFValue]? {
        if case let .object(value) = self {
            return value
        }
        return nil
    }

    /// The string content converted to `Int`, or `nil`.
    public var intValue: Int? {
        stringValue.flatMap(Int.init)
    }
}

/// Errors thrown by ``VDFParser``.
public enum VDFParseError: LocalizedError, Equatable {
    /// A token appeared where the grammar doesn't allow it.
    case unexpectedToken(line: Int)
    /// A quoted string reached the end of its line or the document unclosed.
    case unterminatedString(line: Int)
    /// The document ended inside an unclosed object.
    case unexpectedEnd

    public var errorDescription: String? {
        switch self {
        case let .unexpectedToken(line):
            "Unexpected token at line \(line)"
        case let .unterminatedString(line):
            "Unterminated string at line \(line)"
        case .unexpectedEnd:
            "Unexpected end of document inside an unclosed object"
        }
    }
}

/// Parses the text flavor of Valve's KeyValues format ("VDF"), the format of
/// Steam's `appmanifest_*.acf`, `libraryfolders.vdf`, and `config.vdf`.
///
/// Supported grammar: quoted keys, quoted string values, `{}` nesting,
/// `\\` and `\"` escapes, and `//` line comments. Keys are lowercased on
/// parse because Valve's own files are case-inconsistent (`"AppState"`,
/// `"appid"`, `"StateFlags"`). Duplicate keys keep the last occurrence.
/// Binary VDF is not supported.
public enum VDFParser {
    /// Parses a VDF document into its top-level key-value pairs.
    ///
    /// - Parameter text: The document text.
    /// - Returns: The top-level object, typically a single key like
    ///   `"appstate"` or `"libraryfolders"` mapping to a nested object.
    /// - Throws: ``VDFParseError`` if the document is malformed.
    public static func parse(_ text: String) throws -> [String: VDFValue] {
        var scanner = Scanner(text: text)
        return try parseObjectBody(&scanner, isTopLevel: true)
    }

    // MARK: - Tokenizer

    private enum Token: Equatable {
        case string(String)
        case openBrace
        case closeBrace
    }

    private struct Scanner {
        let text: String
        var index: String.Index
        var line = 1

        init(text: String) {
            self.text = text
            self.index = text.startIndex
        }

        mutating func skipWhitespaceAndComments() {
            while index < text.endIndex {
                let character = text[index]
                if character == "\n" {
                    line += 1
                    index = text.index(after: index)
                } else if character.isWhitespace {
                    index = text.index(after: index)
                } else if character == "/" {
                    let nextIndex = text.index(after: index)
                    if nextIndex < text.endIndex, text[nextIndex] == "/" {
                        while index < text.endIndex, text[index] != "\n" {
                            index = text.index(after: index)
                        }
                    } else {
                        break
                    }
                } else {
                    break
                }
            }
        }

        /// Returns the next token, or `nil` at end of document.
        mutating func nextToken() throws -> Token? {
            skipWhitespaceAndComments()
            guard index < text.endIndex else { return nil }

            switch text[index] {
            case "{":
                index = text.index(after: index)
                return .openBrace
            case "}":
                index = text.index(after: index)
                return .closeBrace
            case "\"":
                return try .string(scanQuotedString())
            default:
                throw VDFParseError.unexpectedToken(line: line)
            }
        }

        private mutating func scanQuotedString() throws -> String {
            let startLine = line
            index = text.index(after: index) // consume the opening quote
            var value = ""

            while index < text.endIndex {
                let character = text[index]
                switch character {
                case "\"":
                    index = text.index(after: index)
                    return value
                case "\\":
                    let nextIndex = text.index(after: index)
                    guard nextIndex < text.endIndex else {
                        throw VDFParseError.unterminatedString(line: startLine)
                    }
                    value.append(text[nextIndex])
                    index = text.index(after: nextIndex)
                case "\n":
                    throw VDFParseError.unterminatedString(line: startLine)
                default:
                    value.append(character)
                    index = text.index(after: index)
                }
            }
            throw VDFParseError.unterminatedString(line: startLine)
        }
    }

    // MARK: - Parser

    private static func parseObjectBody(
        _ scanner: inout Scanner,
        isTopLevel: Bool
    ) throws -> [String: VDFValue] {
        var result: [String: VDFValue] = [:]

        while true {
            guard let token = try scanner.nextToken() else {
                if isTopLevel {
                    return result
                }
                throw VDFParseError.unexpectedEnd
            }

            switch token {
            case .closeBrace:
                if isTopLevel {
                    throw VDFParseError.unexpectedToken(line: scanner.line)
                }
                return result

            case let .string(key):
                result[key.lowercased()] = try parseValue(&scanner)

            case .openBrace:
                throw VDFParseError.unexpectedToken(line: scanner.line)
            }
        }
    }

    private static func parseValue(_ scanner: inout Scanner) throws -> VDFValue {
        guard let token = try scanner.nextToken() else {
            throw VDFParseError.unexpectedEnd
        }
        switch token {
        case let .string(value):
            return .string(value)
        case .openBrace:
            return try .object(parseObjectBody(&scanner, isTopLevel: false))
        case .closeBrace:
            throw VDFParseError.unexpectedToken(line: scanner.line)
        }
    }
}
