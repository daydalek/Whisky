//
//  LinuxDesktopService.swift
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

@MainActor
struct LinuxDesktopService {
    static let methods = [
        "system.desktop.status",
        "system.desktop.install",
        "programs.shortcut.create",
        "system.desktop.resolve"
    ]
    let environment: [String: String]
    let searchPaths: [URL]
    var applications: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let data = environment["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? home.appendingPathComponent(".local/share")
        return data.appendingPathComponent("applications")
    }

    func call(
        _ method: String,
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) async throws -> JSONValue {
        guard Self.methods.contains(method) else { throw BridgeFailure("method_unavailable", "Unknown desktop method") }
        if method == "system.desktop.resolve" {
            return try resolve(params, workspace: workspace)
        }
        let launcher = try launcher(params)
        if method ==
            "programs.shortcut.create" {
            let result = try shortcut(params, launcher: launcher, workspace: workspace)
            if try params.path("destination").standardizedFileURL == applications.standardizedFileURL {
                _ = try await refreshCache()
            }
            return result
        }
        let target = applications.appendingPathComponent("com.franke.Whisky.desktop")
        let contents = LinuxDesktopEntry.contents(
            name: "Whisky",
            launcher: launcher,
            arguments: [],
            handlesFiles: true
        )
        if method == "system.desktop.status" {
            let status = try LinuxDesktopUpdater.status(contents, at: target, arguments: [[]], handlesFiles: true)
            return .object([
                "installed": .bool(status.installed),
                "needsUpdate": .bool(status.needsUpdate),
                "path": .string(target.path)
            ])
        }
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let updated = try LinuxDesktopUpdater.publish(contents, at: target, arguments: [[]], handlesFiles: true)
        let cache = try await refreshCache()
        return .object([
            "installed": .bool(true),
            "path": .string(target.path),
            "cacheUpdated": .bool(cache),
            "updated": .bool(updated)
        ])
    }

    private func launcher(_ params: [String: JSONValue]) throws -> URL {
        let path = try params["launcher"].map { _ in try params.path("launcher") }
            ?? (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).deletingLastPathComponent()
            .appendingPathComponent("whisky-gpui")
        let canonical = path.resolvingSymlinksInPath()
        guard (try? canonical.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isExecutableFile(atPath: path.path)
        else {
            throw BridgeFailure("launcher_unavailable", "Select an installed Whisky frontend executable")
        }
        return path
    }

    private func shortcut(
        _ params: [String: JSONValue],
        launcher: URL,
        workspace: ApplicationWorkspace
    ) throws -> JSONValue {
        let lease = try ContainerRegistry.acquire(workspace)
        defer { ContainerRegistry.release(lease) }
        try ContainerJournal.requireClear(workspace.registry)
        var registry = try ContainerRegistry.Document(workspace)
        let container = try registry.resolve(params)
        let executable = try params.path("executable")
        guard executable.pathExtension.lowercased() == "exe",
              (try? executable.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ==
              true
        else {
            throw BridgeFailure("file_missing", "Select an existing Windows executable")
        }
        let name = params["name"]?.string ?? executable.deletingPathExtension().lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 128,
              !name.contains("/"), !name.contains("\0"), !name.contains("\n"), !name.contains("\r")
        else {
            throw BridgeFailure("invalid_params", "Choose a valid shortcut name")
        }
        let directory = try params.path("destination")
        if directory.standardizedFileURL == applications.standardizedFileURL {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw BridgeFailure("invalid_params", "Select an existing shortcut destination directory")
        }
        let target = directory.appendingPathComponent(name).appendingPathExtension("desktop")
        let id = try registry.containerIdentity(container)
        let relative = Self.programPath(executable, in: container)
        let contents = LinuxDesktopEntry.contents(
            name: name,
            launcher: launcher,
            arguments: ["--open-file", relative, "--container-id", id],
            handlesFiles: false
        )
        let updated = try LinuxDesktopUpdater.publish(contents, at: target, arguments: [
            ["--open-file", relative, "--container-id", id],
            ["--open-file", executable.path, "--container", container.path]
        ], handlesFiles: false)
        return .object([
            "path": .string(target.path),
            "name": .string(name),
            "containerID": .string(id),
            "programPath": .string(relative), "updated": .bool(updated)
        ])
    }

    private static func programPath(_ executable: URL, in container: URL) -> String {
        for path in [executable.standardizedFileURL.path, executable.resolvingSymlinksInPath().path]
            where path.hasPrefix(container.path + "/") {
            return String(path.dropFirst(container.path.count + 1))
        }
        return executable.path
    }

    private func resolve(_ params: [String: JSONValue], workspace: ApplicationWorkspace) throws -> JSONValue {
        guard let lease = try ContainerRegistry.acquireShared(workspace) else {
            throw BridgeFailure("shortcut_unavailable", "Open a persisted container registry first")
        }
        defer { ContainerRegistry.release(lease) }
        try ContainerJournal.requireClear(workspace.registry)
        let registry = try ContainerRegistry.Document(workspace)
        let container = try registry.resolveIdentity(params.text("containerID"))
        let path = try params.text("path")
        guard !path.isEmpty,
              !path.contains("\0")
        else { throw BridgeFailure("invalid_params", "Invalid shortcut path") }
        let absolute = path.hasPrefix("/")
        guard absolute || !path.split(separator: "/", omittingEmptySubsequences: false)
            .contains(where: { $0 == ".." || $0.isEmpty })
        else {
            throw BridgeFailure("invalid_params", "Choose a valid container-relative executable path")
        }
        let executable = absolute ? URL(fileURLWithPath: path) : container.appendingPathComponent(path)
        guard executable.pathExtension.lowercased() == "exe",
              (try? executable.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ==
              true
        else {
            throw BridgeFailure("file_missing", "The shortcut executable is unavailable")
        }
        return .object(["container": .string(container.path), "path": .string(executable.path)])
    }

    private func refreshCache() async throws -> Bool {
        guard let tool = searchPaths.map({ $0.appendingPathComponent("update-desktop-database") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
        else { return false }
        do {
            let result = try await HostCommand.run(
                executable: tool,
                arguments: [applications.path],
                environment: environment,
                timeout: 2
            )
            return result.status == 0 && !result.signalled
        } catch is CancellationError { throw CancellationError() } catch { return false }
    }
}
