//
//  Service+Configuration.swift
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

// MARK: - Container configuration methods

extension ApplicationService {
    func configurationCall(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
        switch method {
        case "configuration.schema": return .array(Self.fields(params).map(Self.describe))
        case "configuration.read":
            let file = try configuration(params)
            return try await .object(file.values(for: Self.fields(params)).mapValues(Self.encode))
        case "configuration.set": return try await setConfiguration(params)
        default: return try await nativeCall(method, params: params)
        }
    }

    private func setConfiguration(_ params: [String: JSONValue]) async throws -> JSONValue {
        let container = try workspace.resolve(params)
        let fieldID = try params.text("field")
        let fields = Self.fields(params)
        guard let field = fields.first(where: { $0.id == fieldID }), let input = params["value"] else {
            throw BridgeFailure("invalid_params", "Unknown field or missing value")
        }
        let value = try Self.decode(input)
        try field.validate(value)
        let file = try configuration(params)
        let current = try await file.values(for: fields)
        if current[field.id] != value {
            let hostFields: Set = [
                "windowsVersion",
                "virtualDesktopEnabled",
                "resolutionPreset",
                "customResolutionWidth",
                "customResolutionHeight"
            ]
            if params["executable"] == nil, hostFields.contains(field.id) {
                guard let native else { throw BridgeFailure(
                    "capability_unavailable",
                    "This setting requires the Wine host adapter"
                ) }
                try await native.configurationChanged(field, value: value, values: current, container: container)
            }
            try await file.update(field, to: value)
        }
        return try await .object(file.values(for: fields).mapValues(Self.encode))
    }

    private static var containerFields: [ConfigurationField] {
        ContainerConfiguration.fields
    }

    private static func fields(_ params: [String: JSONValue]) -> [ConfigurationField] {
        params["executable"] == nil ? containerFields : [
            ContainerConfiguration.choice("programLocale", "语言区域", "locale", "", ContainerConfiguration.locales),
            .init("arguments", "运行参数", path: "arguments", input: .text, defaultValue: .text(""))
        ]
    }

    private nonisolated static func encode(_ value: ConfigurationValue) -> JSONValue {
        switch value {
        case let .boolean(boolean): return .bool(boolean)
        case let .integer(integer): return .integer(Int64(integer))
        case let .text(text): return .string(text)
        }
    }

    private nonisolated static func decode(_ value: JSONValue) throws -> ConfigurationValue {
        switch value {
        case let .bool(boolean): return .boolean(boolean)
        case let .integer(raw):
            guard let integer = Int(exactly: raw) else { break }
            return .integer(integer)
        case let .string(string): return .text(string)
        default: break
        }
        throw BridgeFailure("invalid_params", "Expected a boolean, integer or string setting")
    }

    private nonisolated static func describe(_ field: ConfigurationField) -> JSONValue {
        var result: [String: JSONValue] = [
            "id": .string(field.id),
            "title": .string(field.title),
            "default": encode(field.defaultValue)
        ]
        let hostFields: Set = [
            "windowsVersion",
            "virtualDesktopEnabled",
            "resolutionPreset",
            "customResolutionWidth",
            "customResolutionHeight"
        ]
        result["requires"] = .array(hostFields.contains(field.id) ? [.string("wine.configuration")] : [])
        switch field.input {
        case .toggle: result["input"] = .string("toggle")
        case .text: result["input"] = .string("text")
        case let .number(range):
            result["input"] = .string("number")
            result["min"] = .integer(Int64(range.lowerBound))
            result["max"] = .integer(Int64(range.upperBound))
        case let .choice(options):
            result["input"] = .string("choice")
            result["options"] = .array(options.map { .object(["id": .string($0.id), "title": .string($0.title)]) })
        }
        return .object(result)
    }
}
