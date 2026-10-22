//
//  LinuxFilePicker.swift
//  WhiskyBridge
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

/// The bundled GTK chooser owns its display event loop and returns NUL-delimited paths.
struct LinuxFilePicker: Sendable {
    static let methods = ["system.chooseFolder", "system.chooseFolders", "system.choosePath"]
    typealias Runner = @Sendable (URL, [String], [String: String], TimeInterval) async throws -> HostCommandResult
    private let paths: [URL]
    private let environment: [String: String]
    private let runner: Runner

    init(
        searchPaths: [URL],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runner: @escaping Runner = { try await HostCommand.run(
            executable: $0,
            arguments: $1,
            environment: $2,
            timeout: $3
        ) }
    ) {
        paths = searchPaths
        self.environment = environment
        self.runner = runner
    }

    func call(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
        guard Self.methods.contains(method) else { throw BridgeFailure("method_unavailable", "Unknown file picker") }
        guard let tool = executable else {
            throw BridgeFailure("host_failed", "The file chooser is unavailable; reinstall Whisky")
        }
        guard !environment["DISPLAY", default: ""].isEmpty || !environment["WAYLAND_DISPLAY", default: ""].isEmpty
        else {
            throw BridgeFailure("host_failed", "A graphical desktop session is required to choose files")
        }
        let request = try Request(method: method, params: params)
        let result = try await runner(tool, request.arguments, environment, 310)
        if result.status == 1, !result.signalled {
            return request.reply([])
        }
        if result.status == 5, !result.signalled {
            throw BridgeFailure("host_timeout", "File selection timed out; open the picker again", retryable: true)
        }
        guard result.status == 0, !result.signalled, result.output.last == 0 else {
            throw BridgeFailure("host_failed", "The file chooser could not complete the selection")
        }
        let selected = try result.output.dropLast().split(separator: 0, omittingEmptySubsequences: false).map { bytes in
            guard let text = String(bytes: bytes, encoding: .utf8) else {
                throw BridgeFailure("host_failed", "The selected path requires UTF-8 encoding")
            }
            return text
        }
        guard request.multiple || selected.count == 1 else {
            throw BridgeFailure("host_failed", "The chooser returned multiple paths for a single selection")
        }
        let urls = try selected.map { try request.validate($0) }
        return request.reply(urls)
    }

    var executable: URL? {
        paths.map { $0.appendingPathComponent("whisky-file-picker") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private struct Request {
        let purpose: String
        let echoesPurpose: Bool
        let mode: String
        let multiple: Bool
        let extensions: [String]
        var arguments: [String]

        init(method: String, params: [String: JSONValue]) throws {
            purpose = params["purpose"]?.string ?? ""
            echoesPurpose = method == "system.choosePath"
            multiple = method == "system.chooseFolders"
            mode = method == "system.choosePath" ? params["mode"]?.string ?? "file" : "folder"
            guard ["file", "folder", "save"].contains(mode) else { throw BridgeFailure(
                "invalid_params",
                "Unknown picker mode"
            ) }
            extensions = try Self.extensions(params)
            arguments = ["--file-selection", "--title=\(params["prompt"]?.string ?? "Whisky")", "--timeout=300"]
            if mode == "folder" {
                arguments.append("--directory")
            }
            if mode == "save" {
                arguments += ["--save", "--confirm-overwrite"]
            }
            if multiple {
                arguments.append("--multiple")
            }
            if !extensions.isEmpty, mode != "folder" {
                let patterns = extensions.flatMap { ["*.\($0)", "*.\($0.uppercased())"] }.joined(separator: " ")
                arguments.append("--file-filter=Files | \(patterns)")
            }
            if let initial = try Self.initialPath(params, mode: mode) {
                arguments.append("--filename=\(initial)")
            }
        }

        private static func initialPath(_ params: [String: JSONValue], mode: String) throws -> String? {
            let name = mode == "save" ? params["name"]?.string : nil
            if let name {
                guard !name.isEmpty, !name.contains("/"), !name.contains("\0"), name != ".", name != ".." else {
                    throw BridgeFailure("invalid_params", "Expected a file name")
                }
            }
            guard let start = params["path"]?.string else { return name }
            guard start.hasPrefix("/"), !start.contains("\0") else {
                throw BridgeFailure("invalid_params", "Expected an absolute start path")
            }
            var url = URL(fileURLWithPath: start)
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: start, isDirectory: &directory), !directory.boolValue {
                url.deleteLastPathComponent()
            }
            return name.map { url.appendingPathComponent($0).path } ?? url.path + "/"
        }

        private static func extensions(_ params: [String: JSONValue]) throws -> [String] {
            guard let value = params["extensions"] else { return [] }
            guard case let .array(items) = value
            else { throw BridgeFailure("invalid_params", "Expected file extensions") }
            return try items.map { item in
                guard let text = item.string, !text.isEmpty, text.utf8.count <= 32,
                      text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
                else { throw BridgeFailure("invalid_params", "Invalid file extension") }
                return text.lowercased()
            }
        }

        func validate(_ text: String) throws -> URL {
            guard text.hasPrefix("/"), !text.contains("\0") else {
                throw BridgeFailure("host_failed", "The file chooser returned an invalid path")
            }
            var url = URL(fileURLWithPath: text).standardizedFileURL.resolvingSymlinksInPath()
            if mode == "save", url.pathExtension.isEmpty,
               extensions.count == 1 {
                url.appendPathExtension(extensions[0])
                guard !FileManager.default.fileExists(atPath: url.path) else {
                    throw BridgeFailure(
                        "invalid_params", "Select the complete existing filename to confirm replacement"
                    )
                }
            }
            if mode == "save" {
                guard try url.deletingLastPathComponent().resourceValues(forKeys: [.isDirectoryKey])
                    .isDirectory == true
                else {
                    throw BridgeFailure("invalid_params", "The save directory is unavailable")
                }
            } else {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                guard mode == "folder" ? values.isDirectory == true : values.isRegularFile == true else {
                    throw BridgeFailure("host_failed", "The selection has the wrong file type")
                }
            }
            if mode != "folder", !extensions.isEmpty, !extensions.contains(url.pathExtension.lowercased()) {
                throw BridgeFailure("invalid_params", "Select one of the requested file types")
            }
            return url
        }

        func reply(_ urls: [URL]) -> JSONValue {
            if multiple {
                return .object(["paths": .array(urls.map { .string($0.path) })])
            }
            var value: [String: JSONValue] = ["path": urls.first.map { .string($0.path) } ?? .null]
            if echoesPurpose || !purpose.isEmpty {
                value["purpose"] = .string(purpose)
            }
            return .object(value)
        }
    }
}
