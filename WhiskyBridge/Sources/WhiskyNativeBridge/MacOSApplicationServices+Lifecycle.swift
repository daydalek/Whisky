//
//  MacOSApplicationServices+Lifecycle.swift
//  WhiskyNativeBridge
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

import AppKit
import Foundation
import WhiskyApplication
import WhiskyBridgeProtocol
import WhiskyCore
import WhiskyKit

// MARK: - Bottle lifecycle and host tools

extension MacOSApplicationServices {
    /// `bottle.*` methods other than `bottle.create`. Lifecycle work that can
    /// take longer than a request timeout is a `BridgeJobStore` job, so the
    /// helper stays responsive while a prefix is copied or archived.
    func bottleCall(
        _ method: String,
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) async throws -> JSONValue {
        let container = try workspace.resolve(params)
        switch method {
        case "bottle.rename":
            return try renameBottle(container: container, params: params)
        case "bottle.remove":
            return try removeBottle(container: container, params: params, workspace: workspace)
        case "bottle.move":
            return try moveBottle(container: container, params: params, workspace: workspace)
        case "bottle.duplicate":
            return try duplicateBottle(container: container, params: params, workspace: workspace)
        case "bottle.export":
            return try exportBottle(container: container, params: params, workspace: workspace)
        case "bottle.repair":
            return try repairBottle(container: container)
        case "bottle.cleanCache":
            return try cleanShaderCaches()
        case "bottle.tools":
            return try bottleTool(container: container, params: params)
        default:
            throw BridgeFailure("method_unavailable", "Native method is unavailable")
        }
    }

    /// `folders.moveRoot`: reassign a scanned root and its games to another
    /// container, including their executable choices and metadata snapshots.
    func foldersMoveRoot(
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) async throws -> JSONValue {
        let source = try workspace.resolve(params)
        let targetPath = try params.path("targetContainer")
        let target = try workspace.resolve(["container": .string(targetPath.path)])
        guard source.standardizedFileURL != target.standardizedFileURL else {
            throw BridgeFailure("invalid_params", "Source and target containers are the same")
        }
        let root = try params.path("path")
        let key = FolderGameLibrary.key(for: root, bottleURL: source)
        try await FolderGameLibrary.moveRoot(key, from: source, to: target)
        bottles[source] = nil
        bottles[target] = nil
        return .object([
            "source": .string(source.path),
            "target": .string(target.path),
            "root": .string(root.path)
        ])
    }

    private func renameBottle(container: URL, params: [String: JSONValue]) throws -> JSONValue {
        let name = try params.text("name").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw BridgeFailure("invalid_params", "Bottle name is required") }
        guard let bottle = bottle(container) else {
            throw BridgeFailure("invalid_container", "Wine settings are unreadable")
        }
        bottle.settings.name = name
        bottle.saveBottleSettings()
        bottles[container] = nil
        return .object(["container": .string(container.path), "name": .string(name)])
    }

    private func removeBottle(
        container: URL,
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) throws -> JSONValue {
        let deleteFiles = params["deleteFiles"] == nil ? false : try params.flag("deleteFiles")
        let stopProcesses = params["stopProcesses"] == nil ? true : try params.flag("stopProcesses")
        let name = bottle(container)?.settings.name ?? container.lastPathComponent
        return try jobs.start(name: "bottle.remove") { [self] progress in
            progress(.object(["stage": .string("stopping")]))
            if stopProcesses, let bottle = bottle(container) {
                Wine.killBottle(bottle: bottle)
                ProcessRegistry.shared.clearRegistry(for: container)
            }
            progress(.object(["stage": .string("removing")]))
            SettingsPersistence.shared.flush()
            let target = bottle(container)
            target?.inFlight = true
            defer { target?.inFlight = false }
            // File deletion can take longer than a request timeout; unlink the
            // tree off the helper's actor, then update the registry.
            if deleteFiles {
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.removeItem(at: container)
                }.value
                GameRouting().removeRoutes(toBottle: container)
            }
            let registry = WorkspaceBottleRegistry(registryURL: workspace.registry) { [weak self] url in
                self?.bottle(url)
            }
            var paths = registry.bottlePaths
            paths.removeAll { $0.standardizedFileURL == container.standardizedFileURL }
            registry.bottlePaths = paths
            registry.loadBottles()
            guard !registry.bottlePaths.contains(where: {
                $0.standardizedFileURL == container.standardizedFileURL
            }) else {
                throw BridgeFailure("operation_failed", "Could not deregister the bottle")
            }
            bottles[container] = nil
            return .object([
                "container": .string(container.path),
                "name": .string(name),
                "deletedFiles": .bool(deleteFiles)
            ])
        }
    }

    private func moveBottle(
        container: URL,
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) throws -> JSONValue {
        let parent = try params.path("destination")
        guard let values = try? parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true
        else {
            throw BridgeFailure("invalid_params", "Expected a non-symlink destination directory")
        }
        let destination = parent.appendingPathComponent(container.lastPathComponent, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw BridgeFailure("destination_exists", "A bottle already exists at the destination")
        }
        return try jobs.start(name: "bottle.move") { [self] progress in
            progress(.object(["stage": .string("moving")]))
            let registry = WorkspaceBottleRegistry(registryURL: workspace.registry) { [weak self] url in
                self?.bottle(url)
            }
            BottleOperations.move(bottleAt: container, to: destination, registry: registry)
            guard FileManager.default.fileExists(atPath: destination.path),
                  !FileManager.default.fileExists(atPath: container.path)
            else {
                throw BridgeFailure("operation_failed", "Could not move the bottle")
            }
            bottles[container] = nil
            bottles[destination] = nil
            let name = bottle(destination)?.settings.name ?? destination.lastPathComponent
            return .object(["path": .string(destination.path), "name": .string(name)])
        }
    }

    private func duplicateBottle(
        container: URL,
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) throws -> JSONValue {
        let name = try params.text("name").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw BridgeFailure("invalid_params", "Bottle name is required") }
        return try jobs.start(name: "bottle.duplicate") { [self] progress in
            progress(.object(["stage": .string("copying")]))
            let registry = WorkspaceBottleRegistry(registryURL: workspace.registry) { [weak self] url in
                self?.bottle(url)
            }
            let path = try await BottleOperations.duplicate(
                bottleAt: container,
                newName: name,
                registry: registry
            )
            bottles[path] = nil
            return .object(["path": .string(path.path), "name": .string(name)])
        }
    }

    private func exportBottle(
        container: URL,
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) throws -> JSONValue {
        let destination = try params.path("destination")
        guard destination.pathExtension.lowercased() == "tar" else {
            throw BridgeFailure("invalid_params", "Archive destination must end in .tar")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw BridgeFailure("destination_exists", "A file already exists at the destination")
        }
        return try jobs.start(name: "bottle.export") { [self] progress in
            progress(.object(["stage": .string("archiving")]))
            let registry = WorkspaceBottleRegistry(registryURL: workspace.registry) { [weak self] url in
                self?.bottle(url)
            }
            try await BottleOperations.export(
                bottleAt: container,
                to: destination,
                registry: registry
            )
            return .object(["path": .string(destination.path)])
        }
    }

    private func repairBottle(container: URL) throws -> JSONValue {
        guard let bottle = bottle(container) else {
            throw BridgeFailure("invalid_container", "Wine settings are unreadable")
        }
        return try jobs.start(name: "bottle.repair") { progress in
            progress(.object(["stage": .string("repairing")]))
            _ = try await Wine.repairPrefix(bottle: bottle)
            let result = WinePrefixValidation.validatePrefix(for: bottle)
            guard result.isValid else {
                throw BridgeFailure(
                    "repair_incomplete",
                    "wineboot finished but the prefix still fails validation"
                )
            }
            return .object(["valid": .bool(true)])
        }
    }

    /// Wine's shared D3DMetal/shader cache lives in the per-user cache
    /// directory, exactly where the SwiftUI menu item wipes it. The deletion
    /// itself is a job: a large shader cache can take seconds to unlink.
    private func cleanShaderCaches() throws -> JSONValue {
        let getconf = Process()
        getconf.executableURL = URL(fileURLWithPath: "/usr/bin/getconf")
        getconf.arguments = ["DARWIN_USER_CACHE_DIR"]
        let pipe = Pipe()
        getconf.standardOutput = pipe
        getconf.standardError = FileHandle.nullDevice
        try getconf.run()
        getconf.waitUntilExit()
        guard getconf.terminationStatus == 0 else {
            throw BridgeFailure("host_failed", "Could not resolve the user cache directory")
        }
        let output = try pipe.fileHandleForReading.readToEnd() ?? Data()
        guard let raw = String(data: output, encoding: .utf8) else {
            throw BridgeFailure("host_failed", "Could not resolve the user cache directory")
        }
        let path = URL(fileURLWithPath: raw.trimmingCharacters(in: .whitespacesAndNewlines))
            .appendingPathComponent("d3dm")
        return try jobs.start(name: "bottle.cleanCache") { _ in
            let removed = try await Task.detached(priority: .utility) {
                guard FileManager.default.fileExists(atPath: path.path) else { return false }
                try FileManager.default.removeItem(at: path)
                return true
            }.value
            return .object(["removed": .bool(removed), "path": .string(path.path)])
        }
    }

    private func bottleTool(container: URL, params: [String: JSONValue]) throws -> JSONValue {
        guard let bottle = bottle(container) else {
            throw BridgeFailure("invalid_container", "Wine settings are unreadable")
        }
        let tool = try params.text("tool")
        switch tool {
        case "winecfg", "regedit", "control":
            launchWineTool(tool, bottle: bottle)
        case "terminal":
            try openTerminal(bottle: bottle)
        default:
            throw BridgeFailure("invalid_params", "Unknown Wine tool: \(tool)")
        }
        return .object(["accepted": .bool(true), "tool": .string(tool)])
    }

    /// The tool windows stay open until the user closes them, so the caller is
    /// answered at once and the process runs to completion in the background.
    private func launchWineTool(_ tool: String, bottle: Bottle) {
        Task { @MainActor in
            do {
                switch tool {
                case "winecfg": try await Wine.cfg(bottle: bottle)
                case "regedit": try await Wine.regedit(bottle: bottle)
                default: try await Wine.control(bottle: bottle)
                }
            } catch {
                NSLog("Whisky: failed to launch %@: %@", tool, error.localizedDescription)
            }
        }
    }

    /// Writes a terminal environment script and opens it with the preferred
    /// terminal app. Opening a `.command` document avoids AppleScript
    /// automation prompts for the helper process.
    private func openTerminal(bottle: Bottle) throws {
        let environment = Wine.generateTerminalEnvironmentCommand(bottle: bottle)
        let script = """
        #!/bin/bash
        \(environment)
        cd "$WINEPREFIX" 2>/dev/null || true
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisky-env-\(UUID().uuidString).command")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)

        let terminal = TerminalApp.preferred
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.bundleIdentifier) else {
            guard NSWorkspace.shared.open(url) else {
                throw BridgeFailure("host_failed", "Could not open the terminal script")
            }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { _, error in
            if let error {
                NSLog("Whisky: failed to open terminal script: %@", error.localizedDescription)
            }
        }
    }
}

/// `BottleOperations` reads and rewrites the persisted bottle registry. The
/// bridge host has no `BottleVM`, so this adapter owns `BottleData` and hands
/// the operations the live bottle instances held by the service cache.
@MainActor
private final class WorkspaceBottleRegistry: BottleRegistry {
    private let registryURL: URL
    private let resolver: @MainActor (URL) -> Bottle?

    init(registryURL: URL, resolver: @escaping @MainActor (URL) -> Bottle?) {
        self.registryURL = registryURL
        self.resolver = resolver
    }

    var bottlePaths: [URL] {
        get { BottleData(registryURL: registryURL).paths }
        set {
            var data = BottleData(registryURL: registryURL)
            data.paths = newValue
        }
    }

    func bottle(for url: URL) -> Bottle? {
        resolver(url)
    }

    func loadBottles() {}
}
