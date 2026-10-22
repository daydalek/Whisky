//
//  LinuxApplicationServices.swift
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

/// Portable POSIX/Linux host service adapter for file operations, tool discovery and optional runtime drivers.
@MainActor
public final class LinuxApplicationServices: NativeApplicationServices {
    public typealias FileOpener = @Sendable (URL) throws -> Void

    private let runtimeService: RuntimeService?
    private let openFile: FileOpener
    private let searchPaths: [URL]
    private let picker: LinuxFilePicker

    public init(
        runtime: RuntimeService? = nil,
        searchPaths: [URL]? = nil,
        openFile: FileOpener? = nil
    ) {
        runtimeService = runtime
        let paths = searchPaths ?? Self.defaultSearchPaths()
        self.searchPaths = paths
        let bundled = Bundle.main.executableURL.map { [$0.deletingLastPathComponent()] } ?? []
        picker = LinuxFilePicker(searchPaths: bundled + paths)
        self.openFile = openFile ?? Self.xdgOpen
    }

    public var capabilities: [String] {
        ["system.files", "system.picker"] + (runtimeService == nil ? [] : RuntimeService.capabilities)
    }

    public var methods: [String] {
        ["system.reveal", "system.open", "system.resources"]
            + LinuxFilePicker.methods
            + (runtimeService == nil ? [] : RuntimeService.methods)
    }

    public func configurationChanged(
        _ field: ConfigurationField,
        value: ConfigurationValue,
        values: [String: ConfigurationValue],
        container: URL
    ) async throws {
        throw BridgeFailure("capability_unavailable", "This setting requires the Wine host adapter")
    }

    public func call(
        _ method: String,
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) async throws -> JSONValue {
        guard methods.contains(method) else {
            throw BridgeFailure("method_unavailable", "Native method is unavailable")
        }
        switch method.prefix(while: { $0 != "." }) {
        case "system":
            if LinuxFilePicker.methods.contains(method) { return try await picker.call(method, params: params) }
            return try systemCall(method, params: params, workspace: workspace)
        case "runtime":
            guard let runtimeService else {
                throw BridgeFailure("method_unavailable", "Runtime method is unavailable")
            }
            return try await runtimeService.call(method, params: params, workspace: workspace)
        default:
            throw BridgeFailure("method_unavailable", "Native method is unavailable")
        }
    }

    public func shutdown(applyExitPolicy: Bool) async {
        runtimeService?.stopTracking()
    }

    private func systemCall(
        _ method: String,
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) throws -> JSONValue {
        switch method {
        case "system.resources":
            var tools = ["cabextract", "winetricks", "wine", "wineserver", "xdg-open"].map { name in
                (name, locateTool(name).map { JSONValue.string($0.path) } ?? .null)
            }
            tools.append(("whisky-file-picker", picker.executable.map { .string($0.path) } ?? .null))
            return .object([
                "kitBundle": .null,
                "tools": .object(Dictionary(uniqueKeysWithValues: tools))
            ])
        case "system.reveal", "system.open":
            let container = try workspace.resolve(params)
            let path = params["path"] == nil ? container : try params.path("path")
            guard FileManager.default.fileExists(atPath: path.path) else {
                throw BridgeFailure("file_missing", "Selected file is unavailable")
            }
            if method == "system.reveal" {
                var isDirectory: ObjCBool = false
                _ = FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory)
                return isDirectory.boolValue
                    ? try openTarget(path)
                    : try openTarget(path.deletingLastPathComponent())
            } else {
                return try openTarget(path)
            }
        default:
            throw BridgeFailure("method_unavailable", "Native method is unavailable")
        }
    }

    private func openTarget(_ url: URL) throws -> JSONValue {
        do {
            try openFile(url)
            return .object(["accepted": .bool(true)])
        } catch let failure as BridgeFailure {
            throw failure
        } catch {
            throw BridgeFailure("host_failed", error.localizedDescription)
        }
    }

    private func locateTool(_ name: String) -> URL? {
        for directory in searchPaths {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private nonisolated static func defaultSearchPaths(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        let raw = environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        return raw.split(separator: ":").filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: String($0)) }
    }

    private nonisolated static func xdgOpen(_ url: URL) throws {
        guard let opener = defaultSearchPaths().map({ $0.appendingPathComponent("xdg-open") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
        else {
            throw BridgeFailure("host_failed", "xdg-open is unavailable on this host")
        }
        let process = Process()
        process.executableURL = opener
        process.arguments = [url.path]
        // Let Foundation reap the child process once xdg-open exits.
        process.terminationHandler = { _ in }
        try process.run()
    }
}
