//
//  LinuxWinetricksService.swift
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

/// Linux counterpart of the winetricks bridge methods (`winetricks.catalog`,
/// `winetricks.installed`, `winetricks.install`).
///
/// The verb catalog comes from the shared `verbs.txt` resource and the
/// installed set is read from `<prefix>/winetricks.log`, so browsing and
/// inspecting a bottle work without a host `winetricks` binary. Installing
/// verbs runs the host `winetricks` script with the injected Wine runtime on
/// `PATH` and `WINE`/`WINESERVER`/`WINEPREFIX` set for the bottle.
@MainActor
public final class LinuxWinetricksService {
    public struct Category: Sendable {
        public let id: String
        public let verbs: [(name: String, description: String)]
    }

    nonisolated static let categories: Set<String> = ["apps", "benchmarks", "dlls", "fonts", "games", "settings"]

    private let host: LinuxWineHost?
    private let jobs: BridgeJobStore?
    private let searchPaths: [URL]
    private let loadCatalog: @Sendable () throws -> Data

    public init(
        host: LinuxWineHost? = nil,
        jobs: BridgeJobStore? = nil,
        searchPaths: [URL] = [],
        loadCatalog: @escaping @Sendable () throws -> Data = {
            try GameDatabaseResource.resource("verbs.txt")
        }
    ) {
        self.host = host
        self.jobs = jobs
        self.searchPaths = searchPaths
        self.loadCatalog = loadCatalog
    }

    public var winetricksExecutable: URL? {
        for directory in searchPaths {
            let candidate = directory.appendingPathComponent("winetricks")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    public var canInstall: Bool {
        host != nil && jobs != nil && winetricksExecutable != nil
    }

    public var capabilities: [String] {
        ["winetricks.verbs"] + (canInstall ? ["winetricks.install"] : [])
    }

    public var methods: [String] {
        ["winetricks.catalog", "winetricks.installed"] + (canInstall ? ["winetricks.install"] : [])
    }

    public func call(
        _ method: String,
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) async throws -> JSONValue {
        switch method {
        case "winetricks.catalog":
            let categories = try catalog()
            return .object([
                "categories": .array(categories.map { category in
                    .object([
                        "id": .string(category.id),
                        "verbs": .array(category.verbs.map { verb in
                            .object([
                                "name": .string(verb.name),
                                "description": .string(verb.description)
                            ])
                        })
                    ])
                })
            ])
        case "winetricks.installed":
            let container = try workspace.resolve(params)
            let known = try knownVerbs()
            let installed = Self.installedVerbs(in: container).intersection(known).sorted()
            return .object([
                "verbs": .array(installed.map(JSONValue.string)),
                "fromCache": .bool(true)
            ])
        case "winetricks.install":
            return try install(params: params, workspace: workspace)
        default:
            throw BridgeFailure("method_unavailable", "Winetricks method is unavailable")
        }
    }

    private func install(
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) throws -> JSONValue {
        guard let host, let jobs, let script = winetricksExecutable else {
            throw BridgeFailure("method_unavailable", "Install winetricks on the host to install verbs")
        }
        guard host.canExecute else {
            throw BridgeFailure("runtime_unavailable", host.unavailableReason ?? "The Wine runtime cannot run")
        }
        let container = try workspace.resolve(params)
        let verbs = try Self.requestedVerbs(params)
        let known = try knownVerbs()
        if let unknown = verbs.first(where: { !known.contains($0) }) {
            throw BridgeFailure("invalid_params", "Unknown winetricks verb: \(unknown)")
        }
        let system32 = container.appendingPathComponent("drive_c/windows/system32")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: system32.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw BridgeFailure("prefix_invalid", "The Wine prefix is incomplete; recreate or repair the bottle")
        }
        return try jobs.start(name: "winetricks.install") { progress in
            try await Self.runInstall(
                verbs: verbs,
                known: known,
                container: container,
                script: script,
                host: host,
                emit: progress
            )
        }
    }

    private static func runInstall(
        verbs: [String],
        known: Set<String>,
        container: URL,
        script: URL,
        host: LinuxWineHost,
        emit: @escaping BridgeJobStore.Progress
    ) async throws -> JSONValue {
        let total = verbs.count
        var succeeded: [String] = []
        var failures: [(verb: String, reason: String)] = []
        var exitCodes: [String: JSONValue] = [:]

        for (offset, verb) in verbs.enumerated() {
            try Task.checkCancellation()
            let index = Int64(offset + 1)
            emit(.object([
                "stage": .string("preparing"),
                "verb": .string(verb),
                "index": .integer(index),
                "total": .integer(Int64(total))
            ]))
            let before = installedVerbs(in: container)
            let result = try await runVerb(verb, container: container, script: script, host: host)
            exitCodes[verb] = .integer(Int64(result.status))
            if let lastLine = result.output.split(whereSeparator: \.isNewline).last {
                emit(.object([
                    "stage": .string("output"),
                    "verb": .string(verb),
                    "index": .integer(index),
                    "total": .integer(Int64(total)),
                    "line": .string(String(lastLine.prefix(2_048)))
                ]))
            }
            let after = installedVerbs(in: container)
            // In wow64 prefixes winetricks often exits nonzero after a verb or
            // its sub-verbs were recorded in winetricks.log; match macOS.
            let installed = result.status == 0 || after.contains(verb) || after.count > before.count
            if installed {
                succeeded.append(verb)
                emit(.object([
                    "stage": .string("installed"),
                    "verb": .string(verb),
                    "index": .integer(index),
                    "total": .integer(Int64(total)),
                    "exitCode": .integer(Int64(result.status))
                ]))
            } else {
                let reason = "winetricks exited with code \(result.status)"
                failures.append((verb: verb, reason: reason))
                emit(.object([
                    "stage": .string("failed"),
                    "verb": .string(verb),
                    "index": .integer(index),
                    "total": .integer(Int64(total)),
                    "exitCode": .integer(Int64(result.status)),
                    "line": .string(reason)
                ]))
            }
        }

        let current = installedVerbs(in: container).intersection(known).sorted()
        return .object([
            "verbs": .array(verbs.map(JSONValue.string)),
            "installed": .array(current.map(JSONValue.string)),
            "succeeded": .array(succeeded.map(JSONValue.string)),
            "failed": .array(failures.map { .object([
                "verb": .string($0.verb),
                "reason": .string($0.reason)
            ]) }),
            "exitCodes": .object(exitCodes)
        ])
    }

    private static func runVerb(
        _ verb: String,
        container: URL,
        script: URL,
        host: LinuxWineHost
    ) async throws -> LinuxWineHost.Output {
        // When the host uses an explicit user-mode emulator, give winetricks
        // wrapper scripts for `WINE` and `WINESERVER` so every sub-invocation
        // runs through the same translator. On a native host the raw runtime
        // paths are used unchanged.
        let wrapperDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisky-tricks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: wrapperDir) }
        var wineCommand = host.loader.path
        var wineserverCommand = host.wineserver.path
        var usesEmulator = false
        if case let .emulator(emulator) = host.translation {
            usesEmulator = true
            try FileManager.default.createDirectory(at: wrapperDir, withIntermediateDirectories: true)
            for (name, target) in [("wine", host.loader), ("wineserver", host.wineserver)] {
                let wrapper = wrapperDir.appendingPathComponent(name)
                let body = "#!/bin/sh\nexec \"\(emulator.path)\" \"\(target.path)\" \"$@\"\n"
                try Data(body.utf8).write(to: wrapper)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
            }
            wineCommand = wrapperDir.appendingPathComponent("wine").path
            wineserverCommand = wrapperDir.appendingPathComponent("wineserver").path
        }
        var environment = host.environment(prefix: container)
        environment["WINE"] = wineCommand
        environment["WINESERVER"] = wineserverCommand
        environment["WINETRICKS_LATEST_VERSION_CHECK"] = "disabled"
        LinuxWineHost.applyUsableLocale(to: &environment)
        if usesEmulator {
            // winetricks also invokes bare `wine`/`wineserver` found on PATH;
            // those raw entries are foreign ELFs that would bypass the
            // translator's environment, so point PATH at the wrappers instead.
            let rawBin = host.runtimeURL.appendingPathComponent("bin").path
            let wrapped = environment["PATH"]?
                .components(separatedBy: ":")
                .map { $0 == rawBin ? wrapperDir.path : $0 }
                .joined(separator: ":")
            if let wrapped {
                environment["PATH"] = wrapped
            }
        }

        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisky-winetricks-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else {
            throw BridgeFailure("host_failed", "Could not create a winetricks output file")
        }
        let log = try FileHandle(forWritingTo: logURL)
        defer {
            try? log.close()
            try? FileManager.default.removeItem(at: logURL)
        }
        let process = Process()
        process.executableURL = script
        process.arguments = ["--unattended", verb]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
        try? log.synchronize()
        let data = (try? Data(contentsOf: logURL)) ?? Data()
        return .init(status: status, output: String(decoding: data.suffix(64 * 1_024), as: UTF8.self), timedOut: false)
    }

    // MARK: - Catalog & log parsing

    private func catalog() throws -> [Category] {
        do {
            let data = try loadCatalog()
            guard let text = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            let parsed = Self.parseCatalog(text)
            guard !parsed.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            return parsed
        } catch {
            throw BridgeFailure(
                "resource_missing",
                "The winetricks verb catalog is unavailable: \(error.localizedDescription)"
            )
        }
    }

    private func knownVerbs() throws -> Set<String> {
        try Set(catalog().flatMap(\.verbs).map(\.name))
    }

    public nonisolated static func parseCatalog(_ contents: String) -> [Category] {
        var result: [Category] = []
        var current: String?
        var verbs: [(name: String, description: String)] = []
        func flush() {
            if let current, !verbs.isEmpty {
                result.append(Category(id: current, verbs: verbs))
            }
            verbs = []
        }
        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("=====") {
                flush()
                let name = line.replacingOccurrences(of: "=====", with: "")
                    .trimmingCharacters(in: .whitespaces)
                current = categories.contains(name) ? name : nil
            } else if current != nil {
                let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard let name = parts.first.map(String.init) else { continue }
                let description = parts.count > 1
                    ? parts[1].trimmingCharacters(in: .whitespaces)
                    : ""
                verbs.append((name: name, description: description))
            }
        }
        flush()
        return result
    }

    public nonisolated static func installedVerbs(in container: URL) -> Set<String> {
        let candidates = [
            container.appendingPathComponent("winetricks.log"),
            container.appendingPathComponent("drive_c/winetricks.log")
        ]
        var verbs = Set<String>()
        for url in candidates {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) {
                let token = line.trimmingCharacters(in: .whitespaces)
                    .split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
                if !token.isEmpty, !token.hasPrefix("#") {
                    verbs.insert(token)
                }
            }
        }
        return verbs
    }

    private static func requestedVerbs(_ params: [String: JSONValue]) throws -> [String] {
        guard case let .array(values)? = params["verbs"] else {
            throw BridgeFailure("invalid_params", "Expected an array of winetricks verbs")
        }
        var seen = Set<String>()
        var verbs: [String] = []
        for value in values {
            guard let name = value.string,
                  !name.isEmpty,
                  name.utf8.count <= 128,
                  !name.contains(where: { $0.isWhitespace || $0 == "\0" })
            else {
                throw BridgeFailure("invalid_params", "Winetricks verbs must be nonempty names")
            }
            if seen.insert(name).inserted {
                verbs.append(name)
            }
        }
        guard !verbs.isEmpty, verbs.count <= 64 else {
            throw BridgeFailure("invalid_params", "Install between 1 and 64 winetricks verbs")
        }
        return verbs
    }
}
