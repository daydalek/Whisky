//
//  LinuxWineEngineStore.swift
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
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum LinuxWineEngineStoreError: LocalizedError, Sendable, Equatable {
    case managedImmutable
    case unknownEngine(String)
    case engineInUse(id: String)
    case corruptRegistry(String)
    case engineUnavailable(id: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .managedImmutable:
            "The managed Whisky Wine engine cannot be removed"
        case let .unknownEngine(id):
            "Unknown Wine engine '\(id)'"
        case let .engineInUse(id):
            "Engine '\(id)' is still bound to one or more containers"
        case let .corruptRegistry(reason):
            "Wine engine registry is unreadable: \(reason)"
        case let .engineUnavailable(id, reason):
            "Wine engine '\(id)' is unavailable: \(reason)"
        }
    }
}

/// Persistent JSON registry (`Wine Engines.json`) storing registered external
/// Linux Wine runtimes alongside live managed runtime resolution.
@MainActor
public final class LinuxWineEngineStore {
    public struct ManagedRuntimeState: Sendable {
        public let runtimeURL: URL?
        public let isExternalPinned: Bool
        public let installedVersion: String?
        public let defaultPath: URL

        public init(
            runtimeURL: URL?,
            isExternalPinned: Bool = false,
            installedVersion: String? = nil,
            defaultPath: URL = LinuxWineSetupService.defaultRoot().appendingPathComponent("current")
        ) {
            self.runtimeURL = runtimeURL
            self.isExternalPinned = isExternalPinned
            self.installedVersion = installedVersion
            self.defaultPath = defaultPath
        }
    }

    public struct Entry: Codable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let path: String
    }

    private struct RegistryDocument: Codable, Sendable {
        static let currentVersion = 1
        var version: Int = currentVersion
        var engines: [Entry]
    }

    private static let maxRegistryBytes = 1_048_576

    public let registryURL: URL
    public let locksDirectory: URL
    private let managedProvider: @MainActor () -> ManagedRuntimeState
    private let environmentProvider: @Sendable () -> [String: String]

    public init(
        registryURL: URL = HostPaths.wineEnginesRegistry(),
        locksDirectory: URL? = nil,
        managedProvider: @escaping @MainActor () -> ManagedRuntimeState,
        environmentProvider: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        self.registryURL = registryURL
        self.locksDirectory = locksDirectory
            ?? registryURL.deletingLastPathComponent().appendingPathComponent("Engine Locks", isDirectory: true)
        self.managedProvider = managedProvider
        self.environmentProvider = environmentProvider
    }

    public convenience init(
        setup: LinuxWineSetupService,
        registryURL: URL = HostPaths.wineEnginesRegistry(),
        locksDirectory: URL? = nil,
        environmentProvider: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        self.init(
            registryURL: registryURL,
            locksDirectory: locksDirectory,
            managedProvider: { [weak setup] in
                guard let setup else {
                    return ManagedRuntimeState(runtimeURL: nil)
                }
                return ManagedRuntimeState(
                    runtimeURL: setup.runtimeURL,
                    isExternalPinned: setup.externalRuntime != nil,
                    installedVersion: setup.externalRuntime == nil ? setup.installed()?.version.description : nil,
                    defaultPath: setup.root.appendingPathComponent("current")
                )
            },
            environmentProvider: environmentProvider
        )
    }

    public var environment: [String: String] {
        environmentProvider()
    }

    public func managedEngine() -> LinuxWineEngine {
        let state = managedProvider()
        return LinuxWineEngine.managedDescriptor(
            runtimeURL: state.runtimeURL,
            isExternalPinned: state.isExternalPinned,
            installedVersion: state.installedVersion,
            defaultPath: state.defaultPath,
            environment: environment
        )
    }

    public func list() -> (engines: [LinuxWineEngine], loadError: String?) {
        var result = [managedEngine()]
        do {
            let entries = try withRegistryLock(exclusive: false) { try loadEntries() }
            let env = environment
            for entry in entries {
                result.append(inspect(entry: entry, environment: env))
            }
            return (result, nil)
        } catch {
            return (result, error.localizedDescription)
        }
    }

    public func register(at path: URL, name: String? = nil) throws -> LinuxWineEngine {
        let detected = try LinuxWineEngine.detect(
            id: UUID().uuidString.lowercased(),
            name: name,
            at: path,
            managed: false,
            environment: environment
        )
        let storedEntry = try withRegistryLock(exclusive: true) {
            var entries = try loadEntries()
            let canonicalRoot = detected.rootURL.resolvingSymlinksInPath().standardizedFileURL.path
            let canonicalRuntime = detected.runtimeURL.resolvingSymlinksInPath().standardizedFileURL.path
            if let existing = entries.first(where: { entry in
                let url = URL(fileURLWithPath: entry.path).resolvingSymlinksInPath().standardizedFileURL.path
                return url == canonicalRoot || url == canonicalRuntime
            }) {
                return existing
            }
            let entry = Entry(id: detected.id, name: detected.name, path: canonicalRoot)
            entries.append(entry)
            try saveEntries(entries)
            return entry
        }
        return LinuxWineEngine(
            id: storedEntry.id,
            name: storedEntry.name,
            rootURL: detected.rootURL,
            runtimeURL: detected.runtimeURL,
            managed: false,
            available: detected.available,
            error: detected.error,
            version: detected.version,
            architectures: detected.architectures,
            fingerprint: detected.fingerprint,
            translation: detected.translation,
            features: detected.features
        )
    }

    public func remove(id: String, inUseBy: (String) -> Bool) throws {
        guard id != LinuxWineEngine.managedID else {
            throw LinuxWineEngineStoreError.managedImmutable
        }
        try withRegistryLock(exclusive: true) {
            var entries = try loadEntries()
            guard let index = entries.firstIndex(where: { $0.id == id }) else {
                throw LinuxWineEngineStoreError.unknownEngine(id)
            }
            if inUseBy(id) {
                throw LinuxWineEngineStoreError.engineInUse(id: id)
            }
            entries.remove(at: index)
            try saveEntries(entries)
        }
    }

    public func resolve(id: String) throws -> LinuxWineEngine {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetID = trimmed.isEmpty ? LinuxWineEngine.managedID : trimmed
        if targetID == LinuxWineEngine.managedID {
            let engine = managedEngine()
            guard engine.available else {
                throw LinuxWineEngineStoreError.engineUnavailable(
                    id: targetID,
                    reason: engine.error ?? "The managed Wine runtime is not installed"
                )
            }
            return engine
        }
        let entries = try withRegistryLock(exclusive: false) { try loadEntries() }
        guard let entry = entries.first(where: { $0.id == targetID }) else {
            throw LinuxWineEngineStoreError.unknownEngine(targetID)
        }
        let engine = inspect(entry: entry, environment: environment)
        guard engine.available else {
            throw LinuxWineEngineStoreError.engineUnavailable(
                id: targetID,
                reason: engine.error ?? "The registered engine is unavailable"
            )
        }
        return engine
    }

    /// Reads an engine descriptor even if unavailable (used by `wine.engines.selection`
    /// so UI can still show the broken/missing engine and allow rebinding).
    public func lookupDescriptor(id: String) -> LinuxWineEngine {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetID = trimmed.isEmpty ? LinuxWineEngine.managedID : trimmed
        if targetID == LinuxWineEngine.managedID {
            return managedEngine()
        }
        if let entries = try? withRegistryLock(exclusive: false, { try loadEntries() }),
           let entry = entries.first(where: { $0.id == targetID }) {
            return inspect(entry: entry, environment: environment)
        }
        return LinuxWineEngine(
            id: targetID,
            name: targetID,
            rootURL: URL(fileURLWithPath: "/"),
            runtimeURL: URL(fileURLWithPath: "/"),
            managed: false,
            available: false,
            error: "The selected Wine engine is not registered or no longer usable",
            features: LinuxWineEngine.featureStatuses(managed: false)
        )
    }

    public func anyEngineAvailable() -> Bool {
        list().engines.contains { $0.available }
    }

    public func resolveHost(for container: URL) throws -> (engine: LinuxWineEngine, host: LinuxWineHost, overrides: [String: String]) {
        let binding = try ConfigurationFile.wineEngineBinding(
            at: container.appendingPathComponent("Metadata.plist")
        )
        let engine = try resolve(id: binding.engineID)
        guard let host = engine.makeHost(environment: environment), host.canExecute else {
            throw BridgeFailure(
                "runtime_unavailable",
                engine.error ?? "The Wine runtime cannot run on this host"
            )
        }
        return (engine, host, binding.featureOverrides)
    }

    public func acquireSharedLease(for engineID: String) throws -> LinuxWineEngineLease {
        try LinuxWineEngineLease.acquireShared(engineID: engineID, locksDirectory: locksDirectory)
    }

    public func acquireExclusiveLease(for engineID: String) throws -> LinuxWineEngineLease {
        try LinuxWineEngineLease.acquireExclusive(engineID: engineID, locksDirectory: locksDirectory)
    }

    // MARK: - Persistence & Inspection

    private func inspect(entry: Entry, environment: [String: String]) -> LinuxWineEngine {
        let url = URL(fileURLWithPath: entry.path)
        do {
            return try LinuxWineEngine.detect(
                id: entry.id,
                name: entry.name,
                at: url,
                managed: false,
                environment: environment
            )
        } catch {
            return LinuxWineEngine(
                id: entry.id,
                name: entry.name,
                rootURL: url,
                runtimeURL: url,
                managed: false,
                available: false,
                error: error.localizedDescription,
                features: LinuxWineEngine.featureStatuses(managed: false)
            )
        }
    }

    private func loadEntries() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: registryURL.path) else {
            return []
        }
        let handle = try FileHandle(forReadingFrom: registryURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maxRegistryBytes + 1) ?? Data()
        guard data.count <= Self.maxRegistryBytes else {
            throw LinuxWineEngineStoreError.corruptRegistry("Registry exceeds 1 MiB limit")
        }
        guard !data.isEmpty else { return [] }
        do {
            let document = try JSONDecoder().decode(RegistryDocument.self, from: data)
            guard document.version == RegistryDocument.currentVersion else {
                throw LinuxWineEngineStoreError.corruptRegistry("Unsupported version \(document.version)")
            }
            return document.engines
        } catch let error as LinuxWineEngineStoreError {
            throw error
        } catch {
            throw LinuxWineEngineStoreError.corruptRegistry(error.localizedDescription)
        }
    }

    private func saveEntries(_ entries: [Entry]) throws {
        try FileManager.default.createDirectory(
            at: registryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(RegistryDocument(engines: entries))
        try data.write(to: registryURL, options: .atomic)
    }

    private func withRegistryLock<T>(exclusive: Bool, _ operation: () throws -> T) throws -> T {
        let lockURL = registryURL.appendingPathExtension("lock")
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer {
            _ = flock(fd, LOCK_UN)
            close(fd)
        }
        guard flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            let err = errno
            if err == EWOULDBLOCK || err == EAGAIN {
                throw BridgeFailure("engine_busy", "Wine engine registry is busy", retryable: true)
            }
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        return try operation()
    }
}
