//
//  LinuxBottleCreationService.swift
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

/// Creates a Linux bottle around an injected Wine runtime.
///
/// This is the Linux counterpart of `BottleCreationService` (WhiskyKit):
/// it creates a uniquely named directory, boots its Wine prefix, writes the
/// portable metadata plist and registers the directory in `BottleVM.plist`.
/// The long-running Wine work is exposed as a bridge job so the UI can poll
/// progress and keep the helper responsive.
@MainActor
public final class LinuxBottleCreationService {
    public let host: LinuxWineHost
    private let jobs: BridgeJobStore?
    private var cachedWineVersion: String?

    public var runtimeURL: URL {
        host.runtimeURL
    }

    public init?(host: LinuxWineHost, jobs: BridgeJobStore? = nil) {
        let runtimeLibrary = host.runtimeURL.appendingPathComponent("lib")
        guard (try? runtimeLibrary.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else { return nil }
        self.host = host
        self.jobs = jobs
    }

    public convenience init?(runtimeURL: URL, jobs: BridgeJobStore? = nil) {
        guard let host = LinuxWineHost(runtimeURL: runtimeURL) else { return nil }
        self.init(host: host, jobs: jobs)
    }

    public var canCreate: Bool {
        jobs != nil
    }

    /// Starts a `bottle.create` job. Parameters match the macOS bridge:
    /// `name`, `parent`, and the `WinVersion` raw value in `windowsVersion`.
    public func create(
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) throws -> JSONValue {
        guard let jobs else {
            throw BridgeFailure("method_unavailable", "Bottle creation is unavailable")
        }
        guard host.canExecute else {
            throw BridgeFailure("runtime_unavailable", host.unavailableReason ?? "The Wine runtime cannot run")
        }
        let name = try params.text("name").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 128,
              !name.contains("/"), !name.contains("\0"), !name.contains("\n"), !name.contains("\r")
        else {
            throw BridgeFailure("invalid_params", "Choose a valid bottle name")
        }
        let parent = try params.path("parent")
        let windowsVersion = try params.text("windowsVersion")
        guard let version = Self.normalizedWindowsVersion(windowsVersion) else {
            throw BridgeFailure("invalid_params", "Unknown Windows version")
        }
        // Validate the registry before creating anything on disk.
        _ = try workspace.containers()
        return try jobs.start(name: "bottle.create") { [self] progress in
            try await createBottle(
                name: name,
                parent: parent,
                windowsVersion: version,
                workspace: workspace,
                progress: progress
            )
        }
    }

    /// The injected runtime's version, used by `setup.status`. `nil` when
    /// the runtime cannot execute on this host.
    public func wineVersion() async -> String? {
        if let cachedWineVersion {
            return cachedWineVersion
        }
        guard host.canExecute else { return nil }
        let prefix = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisky-version-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: prefix) }
        // `--version` returns before any prefix or server is created.
        guard let result = try? await host.run(
            host.loader,
            arguments: ["--version"],
            prefix: prefix,
            environment: ["WINEDEBUG": "-all"],
            timeout: .seconds(4)
        ), result.status == 0
        else { return nil }
        let version = result.output
            .split(whereSeparator: \.isNewline)
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let version, !version.isEmpty else { return nil }
        cachedWineVersion = version
        return version
    }

    private func createBottle(
        name: String,
        parent: URL,
        windowsVersion: String,
        workspace: ApplicationWorkspace,
        progress: BridgeJobStore.Progress
    ) async throws -> JSONValue {
        progress(.object(["stage": .string("initializing")]))
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw BridgeFailure(
                "destination_unavailable",
                "Could not create the bottle location: \(error.localizedDescription)"
            )
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw BridgeFailure("destination_unavailable", "The bottle location is not a directory")
        }

        let destination = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        } catch {
            throw BridgeFailure(
                "destination_unavailable",
                "Could not create the bottle directory: \(error.localizedDescription)"
            )
        }

        do {
            try await bootstrapPrefix(at: destination, windowsVersion: windowsVersion)
            try Task.checkCancellation()
            try writeMetadata(name: name, windowsVersion: windowsVersion, at: destination)
            try Task.checkCancellation()
            progress(.object(["stage": .string("registering")]))
            try await register(destination, workspace: workspace)
            return .object([
                "path": .string(destination.path),
                "name": .string(name)
            ])
        } catch {
            // The UUID directory belongs to this job; a failed create must not
            // leave a half-booted prefix in the bottle list.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func bootstrapPrefix(at destination: URL, windowsVersion: String) async throws {
        try await runWine(
            ["wineboot", "-u"],
            prefix: destination,
            action: "Wine prefix initialization"
        )
        try Task.checkCancellation()
        try await runWine(
            ["winecfg", "-v", windowsVersion],
            prefix: destination,
            action: "Windows version setup"
        )
        try Task.checkCancellation()

        let system32 = destination.appendingPathComponent("drive_c/windows/system32", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: system32.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw BridgeFailure("prefix_boot_failed", "Wine did not create a usable prefix")
        }

        // Let wineserver flush the registry before metadata and registration.
        _ = try? await host.run(
            host.wineserver,
            arguments: ["-w"],
            prefix: destination,
            timeout: .seconds(60)
        )
    }

    private func writeMetadata(name: String, windowsVersion: String, at destination: URL) throws {
        // Matches the keys the portable configuration schema and macOS
        // BottleSettings decoder read. Missing optional config blocks default.
        let metadata: [String: Any] = [
            "info": ["name": name],
            "wineConfig": ["windowsVersion": windowsVersion]
        ]
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: metadata,
                format: .xml,
                options: 0
            )
            try data.write(
                to: destination.appendingPathComponent("Metadata.plist"),
                options: .atomic
            )
        } catch {
            throw BridgeFailure(
                "metadata_write_failed",
                "Could not write bottle metadata: \(error.localizedDescription)"
            )
        }
    }

    private func register(_ destination: URL, workspace: ApplicationWorkspace) async throws {
        var lastFailure: BridgeFailure?
        for attempt in 0 ..< 10 {
            try Task.checkCancellation()
            do {
                let lease = try ContainerRegistry.acquire(workspace)
                defer { ContainerRegistry.release(lease) }
                try ContainerJournal.requireClear(workspace.registry)
                var registry = try ContainerRegistry.Document(workspace, allowMissing: true)
                let canonical = ContainerRegistry.canonical(destination)
                if !registry.paths.contains(where: { ContainerRegistry.canonical($0) == canonical }) {
                    try registry.save(registry.paths + [destination])
                }
                return
            } catch let failure as BridgeFailure where failure.code == "busy" && attempt < 9 {
                // A library read or lifecycle operation can hold the registry
                // briefly; wait instead of failing a freshly booted bottle.
                lastFailure = failure
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                throw error
            }
        }
        throw lastFailure ?? BridgeFailure("registry_write_failed", "Could not register the bottle")
    }

    @discardableResult
    private func runWine(_ arguments: [String], prefix: URL, action: String) async throws -> String {
        let result = try await host.run(
            host.loader,
            arguments: arguments,
            prefix: prefix,
            environment: [
                "WINEARCH": "win64",
                "WINEDEBUG": "-all",
                // Mono and Gecko first-run downloads would block an unattended boot.
                "WINEDLLOVERRIDES": "mscoree,mshtml=d"
            ],
            outputLimit: 64 * 1_024
        )
        guard result.status == 0 else {
            throw BridgeFailure(
                "prefix_boot_failed",
                "\(action) failed (Wine exit \(result.status)): \(result.output.suffix(2_000))"
            )
        }
        return result.output
    }

    private static func normalizedWindowsVersion(_ raw: String) -> String? {
        let value = raw == "winxp" ? "winxp64" : raw
        let supported: Set<String> = ["winxp64", "win7", "win8", "win81", "win10", "win11"]
        return supported.contains(value) ? value : nil
    }
}
