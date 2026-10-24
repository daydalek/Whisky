//
//  ConfigurationFile.swift
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

public enum ConfigurationPlatform: String, Codable, CaseIterable, Sendable {
    case macOS = "macos"
    case linux

    public static let all: Set<Self> = Set(allCases)

    public static var current: Self {
        #if os(Linux)
        .linux
        #elseif os(macOS)
        .macOS
        #else
        // Unknown platforms are treated as Linux so macOS-only options stay hidden.
        .linux
        #endif
    }
}

public enum ConfigurationValue: Equatable, Sendable {
    case boolean(Bool)
    case text(String)
    case integer(Int)
}

public struct ConfigurationChoice: Equatable, Sendable, Identifiable, CustomStringConvertible {
    public let id: String
    public let title: String
    public let titleKey: String
    public let platforms: Set<ConfigurationPlatform>
    public var description: String {
        title
    }

    public init(
        _ id: String,
        _ title: String,
        titleKey: String? = nil,
        platforms: Set<ConfigurationPlatform> = ConfigurationPlatform.all
    ) {
        self.id = id
        self.title = title
        self.titleKey = titleKey ?? (id.isEmpty ? "config.option.auto" : "config.option.\(id)")
        self.platforms = platforms
    }
}

public struct ConfigurationField: Identifiable, Sendable {
    public enum Input: Sendable {
        case toggle
        case text
        case number(ClosedRange<Int>)
        case choice([ConfigurationChoice])
    }

    public let id: String
    public let title: String
    public let titleKey: String
    public let path: [String]
    public let input: Input
    public let defaultValue: ConfigurationValue
    public let taggedEnum: Bool
    public let removesEmptyText: Bool
    public let requires: [String]
    public let platforms: Set<ConfigurationPlatform>

    public init(
        _ id: String,
        _ title: String,
        titleKey: String? = nil,
        path: String,
        input: Input,
        defaultValue: ConfigurationValue,
        taggedEnum: Bool = false,
        removesEmptyText: Bool = false,
        requires: [String] = [],
        platforms: Set<ConfigurationPlatform> = ConfigurationPlatform.all
    ) {
        self.id = id
        self.title = title
        self.titleKey = titleKey ?? "config.field.\(id)"
        self.path = path.components(separatedBy: ".")
        self.input = input
        self.defaultValue = defaultValue
        self.taggedEnum = taggedEnum
        self.removesEmptyText = removesEmptyText
        self.requires = requires
        self.platforms = platforms
    }

    public func filtered(for platform: ConfigurationPlatform) -> Self? {
        guard platforms.contains(platform) else { return nil }
        guard case let .choice(options) = input else { return self }
        let available = options.filter { $0.platforms.contains(platform) }
        guard !available.isEmpty else { return nil }
        return Self(
            id,
            title,
            titleKey: titleKey,
            path: path.joined(separator: "."),
            input: .choice(available),
            defaultValue: platform == .linux && id == "enhancedSync" ? .text("esync") : defaultValue,
            taggedEnum: taggedEnum,
            removesEmptyText: removesEmptyText,
            requires: requires,
            platforms: platforms
        )
    }

    public func validate(_ value: ConfigurationValue) throws {
        let valid: Bool = switch (input, value) {
        case (.toggle, .boolean), (.text, .text): true
        case let (.number(range), .integer(number)): range.contains(number)
        case let (.choice(options), .text(text)): options.contains { $0.id == text }
        default: false
        }
        if !valid {
            throw ConfigurationError.invalidValue(title)
        }
    }
}

public enum ConfigurationError: LocalizedError {
    case invalidValue(String)
    public var errorDescription: String? {
        switch self {
        case let .invalidValue(title): "设置值超出允许范围：\(title)"
        }
    }
}

/// Field patches read the latest document while locked and retain unknown keys.
public actor ConfigurationFile {
    public let url: URL
    private let locking: any ActivityFileLocking
    private let fallbackURL: URL?

    public init(url: URL, locking: any ActivityFileLocking, fallbackURL: URL? = nil) {
        self.url = url
        self.locking = locking
        self.fallbackURL = fallbackURL
    }

    public func values(for fields: [ConfigurationField]) throws -> [String: ConfigurationValue] {
        let (document, _) = try load()
        return Dictionary(uniqueKeysWithValues: fields.map { ($0.id, Self.value($0, in: document)) })
    }

    public func update(_ field: ConfigurationField, to value: ConfigurationValue) throws {
        try field.validate(value)
        try mutate { document in
            let previous = Self.value(field, in: document)
            guard previous != value else { return }
            let encoded: Any? = switch value {
            case let .boolean(flag): flag
            case let .integer(number): number
            case let .text(text): text.isEmpty && field.removesEmptyText ? nil
                : field.taggedEnum ? [text: [String: String]()] as Any : text as Any
            }
            try Self.set(encoded, at: field.path[...], in: &document)
            if field.id == "graphicsBackend" {
                try Self.set(false, at: ["launcherConfig", "backendSwitchedByLauncher"][...], in: &document)
            }
            if field.id == "programLocale", case let .text(locale) = value {
                if let existing = document["environment"], !(existing is [String: String]) {
                    throw CocoaError(.fileReadCorruptFile)
                }
                var environment = document["environment"] as? [String: String] ?? [:]
                for key in ["LANG", "LC_ALL"] {
                    environment[key] = locale.isEmpty ? nil : locale
                }
                document["environment"] = environment
            }
        }
    }

    public func strings(at path: String) throws -> [String: String] {
        let (document, _) = try load()
        var node: Any = document
        for key in path.components(separatedBy: ".") {
            guard let next = (node as? [String: Any])?[key] else { return [:] }
            node = next
        }
        guard let strings = node as? [String: String] else { throw CocoaError(.fileReadCorruptFile) }
        return strings
    }

    public func setEnvironmentVariable(_ key: String, value: String?) throws {
        guard !key.isEmpty, !key.contains("="), !key.contains("\0"), !(value?.contains("\0") ?? false)
        else { throw ConfigurationError.invalidValue("环境变量名称或内容") }
        try mutate { document in
            if let existing = document["environment"], !(existing is [String: String]) {
                throw CocoaError(.fileReadCorruptFile)
            }
            var variables = document["environment"] as? [String: String] ?? [:]
            variables[key] = value
            document["environment"] = variables
        }
    }

    func mutate(_ operation: (inout [String: Any]) throws -> Void) throws {
        try locking.withExclusiveLock(at: url.appendingPathExtension("lock")) {
            var (document, format) = try load()
            let before = document as NSDictionary
            try operation(&document)
            guard !before.isEqual(to: document) else { return }
            let data = try PropertyListSerialization.data(fromPropertyList: document, format: format, options: 0)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }
    }

    func load() throws -> ([String: Any], PropertyListSerialization.PropertyListFormat) {
        let source = FileManager.default.fileExists(atPath: url.path) ? url : fallbackURL ?? url
        guard FileManager.default.fileExists(atPath: source.path) else { return ([:], .binary) }
        guard try (source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 16 * 1_024 * 1_024
        else { throw CocoaError(.fileReadTooLarge) }
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: source), format: &format)
            as? [String: Any]
        else { throw CocoaError(.fileReadCorruptFile) }
        return (object, format)
    }

    private static func value(_ field: ConfigurationField, in document: [String: Any]) -> ConfigurationValue {
        // BottleSettings migrates legacy DXVK selection when graphicsConfig is absent.
        if field.path == ["graphicsConfig", "backend"], document["graphicsConfig"] == nil,
           (document["dxvkConfig"] as? [String: Any])?["dxvk"] as? Bool == true {
            return .text("dxvk")
        }
        var node: Any = document
        for key in field.path {
            guard let next = (node as? [String: Any])?[key] else { return field.defaultValue }
            node = next
        }
        let value: ConfigurationValue
        switch field.input {
        case .toggle:
            guard let number = node as? NSNumber,
                  Self.isBoolean(number)
            else { return field.defaultValue }
            value = .boolean(number.boolValue)
        case .number:
            guard let number = node as? NSNumber else { return field.defaultValue }
            value = .integer(number.intValue)
        case .text, .choice:
            let text = field.taggedEnum ? (node as? [String: Any])?.keys.first : node as? String
            guard let text else { return field.defaultValue }
            value = .text(text)
        }
        do { try field.validate(value)
            return value
        } catch { return field.defaultValue }
    }

    private static func set(_ value: Any?, at path: ArraySlice<String>, in document: inout [String: Any]) throws {
        guard let head = path.first else { throw CocoaError(.coderInvalidValue) }
        if path.count == 1 {
            document[head] = value
            return
        }
        if let existing = document[head], !(existing is [String: Any]) {
            throw CocoaError(.fileReadCorruptFile)
        }
        var child = document[head] as? [String: Any] ?? [:]
        try set(value, at: path.dropFirst(), in: &child)
        document[head] = child
    }

    private static let booleanObjCTypes: Set<String> = [
        String(cString: NSNumber(value: true).objCType),
        String(cString: NSNumber(value: false).objCType),
        "c",
        "B"
    ]

    private static func isBoolean(_ number: NSNumber) -> Bool {
        booleanObjCTypes.contains(String(cString: number.objCType))
    }
}
