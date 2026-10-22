//
//  GameReferenceService.swift
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

/// Local identity matching and source configuration references for file-only sessions.
@MainActor public struct GameReferenceService {
    public static let methods = ["gameConfig.match"]
    private let load: @Sendable () throws -> Data

    public init(load: @escaping @Sendable () throws -> Data = { try GameDatabaseResource.data() }) {
        self.load = load
    }

    public func match(params: [String: JSONValue], workspace: ApplicationWorkspace) async throws -> JSONValue {
        let record = try await workspace.entry(params)
        let executable: URL? = if case let .program(url) = record.launch {
            url
        } else {
            nil
        }
        let appID: Int? = if case let .steam(appID) = record.launch {
            appID
        } else {
            nil
        }
        let size = executable.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.map(Int64.init)
        let metadata = ProgramMetadata(
            exeName: executable?.lastPathComponent ?? record.name,
            exeURL: executable,
            fileSize: size,
            steamAppId: appID,
            installPath: executable?.deletingLastPathComponent().path
        )
        let (identities, entries) = try database()
        let matches = GameIdentityMatcher.match(metadata: metadata, against: identities).prefix(3)
        return .object(["matches": .array(matches.map { match in
            let entry = entries[match.index]
            let variants = entry.object?["variants"]?.array ?? []
            let variant = variants.first { $0.object?["isDefault"] == .bool(true) } ?? variants.first
            let minimum = entry.object?["constraints"]?.object?["minMacOSVersion"]?.string
            let reference = minimum.map { "参考平台：macOS \($0)+。" } ?? "参考平台：macOS。"
            return .object([
                "entry": entry,
                "confidence": .number(match.confidence),
                "explanation": .string(match.explanation),
                "variantID": .string(variant?.object?["id"]?.string ?? ""),
                "changes": .array(Self.references(variant)),
                "canApply": .bool(false),
                "referencePlatform": .string("macos"),
                "availabilityReason": .string(reference + "当前会话提供识别与配置参考；运行时适配器接入后可应用。")
            ])
        })])
    }

    private func database() throws -> ([GameIdentityRecord], [JSONValue]) {
        do {
            let data = try load()
            let identities = try GameDatabaseResource.identities(in: data)
            let raw = try JSONDecoder().decode(JSONValue.self, from: data)
            guard let entries = raw.object?["entries"]?.array, entries.count == identities.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return (identities, entries)
        } catch {
            throw BridgeFailure("database_unavailable", "GameDB 参考数据库读取失败，请恢复应用资源后重新读取")
        }
    }

    private static func references(_ variant: JSONValue?) -> [JSONValue] {
        guard let variant = variant?.object else { return [] }
        var result: [JSONValue] = []
        let titles = [
            "graphicsBackend": "图形后端",
            "dxvk": "DXVK",
            "dxvkAsync": "DXVK Async",
            "enhancedSync": "增强同步",
            "shaderCacheEnabled": "着色器缓存",
            "avxEnabled": "AVX",
            "sequoiaCompatMode": "Sequoia 兼容模式"
        ]
        for (key, value) in (variant["settings"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
            result.append(reference("参考设置", titles[key] ?? key, display(value)))
        }
        for (key, value) in (variant["environmentVariables"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
            result.append(reference("参考环境变量", key, display(value)))
        }
        for value in variant["dllOverrides"]?.array ?? [] {
            if let name = value.object?["dllName"]?.string, let mode = value.object?["mode"] {
                result.append(reference("参考 DLL", name, display(mode)))
            }
        }
        for value in variant["winetricksVerbs"]?.array ?? [] {
            if let name = value.string {
                result.append(reference("参考组件", name, "列入原始配置"))
            }
        }
        return result
    }

    private static func reference(_ category: String, _ setting: String, _ value: String) -> JSONValue {
        .object([
            "category": .string(category),
            "setting": .string(setting),
            "current": .string("—"),
            "next": .string(value),
            "highImpact": .bool(false)
        ])
    }

    private static func display(_ value: JSONValue) -> String {
        if let text = value.string {
            return text
        }
        if value == .bool(true) {
            return "开启"
        }
        if value == .bool(false) {
            return "关闭"
        }
        guard let data = try? JSONEncoder().encode(value) else { return "—" }
        return String(bytes: data, encoding: .utf8) ?? "—"
    }
}

extension ApplicationService {
    func gameConfigCall(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
        if method == "gameConfig.match", native?.methods.contains(method) != true {
            return try await GameReferenceService().match(params: params, workspace: workspace)
        }
        return try await nativeCall(method, params: params)
    }
}
