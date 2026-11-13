//
//  WineEngineStore.swift
//  WhiskyKit
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
import os.log

private let storeLogger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "WineEngineStore")

/// Registry of user-added external Wine engines.
///
/// The registry is a small JSON document (records only: id, name, root path)
/// shared by every process that reads it — the app, the bridge helper and
/// `WhiskyCmd` — independent of any preferences domain. Mutations hold an
/// `flock` on a sibling lock file and publish through ``DurableAtomicFile``,
/// so a crash mid-write can't tear the file and two writers can't interleave.
///
/// Engine *descriptors* are never persisted: every read re-runs the static
/// ``WineEngine/detect(at:id:name:)`` check, so a tree moved, replaced or
/// deleted after registration shows up as unavailable with a reason rather
/// than as a stale success. The `managed` engine is always present, is not
/// stored in the file, and cannot be removed.
public final class WineEngineStore: @unchecked Sendable {
    /// Registry shared by the app, the bridge and the CLI.
    public static let shared = WineEngineStore()

    /// Default registry location: `~/Library/Application Support/<bundle>/Wine Engines.json`.
    public static var defaultRegistryURL: URL {
        WhiskyWineInstaller.applicationFolder.appending(path: "Wine Engines").appendingPathExtension("json")
    }

    /// The registry file this store reads and writes. Injectable for tests.
    public let registryURL: URL

    /// Engine ids still bound by a registered container; removal refuses to
    /// orphan them. Injected so the store itself never scans bottle metadata.
    public var referencedEngineIDs: @Sendable () -> Set<String>

    /// The error `list()` last hit reading the registry, surfaced so callers
    /// can report corruption instead of silently showing only the managed row.
    /// `nil` after a clean read.
    public var lastLoadError: WineEngineError? {
        lock.lock()
        defer { lock.unlock() }
        return lastLoadErrorStorage
    }

    private var lastLoadErrorStorage: WineEngineError?

    private let lock = NSLock()

    /// - Parameters:
    ///   - registryURL: Registry file location. Defaults to
    ///     ``defaultRegistryURL``; tests pass a temp path.
    ///   - referencedEngineIDs: Provider of engine ids still in use by
    ///     registered containers. Defaults to scanning the shared bottle
    ///     registry's `Metadata.plist` files.
    public init(
        registryURL: URL = WineEngineStore.defaultRegistryURL,
        referencedEngineIDs: (@Sendable () -> Set<String>)? = nil
    ) {
        self.registryURL = registryURL
        self.referencedEngineIDs = referencedEngineIDs ?? Self.defaultReferencedEngineIDs
    }

    // MARK: - Registry file

    private struct Registry: Codable {
        var version: Int
        var engines: [Record]
    }

    private struct Record: Codable {
        var id: String
        var name: String
        var path: String
    }

    private static let registryVersion = 1

    /// Hard bound on registry size — the file is a handful of small records;
    /// anything bigger is corruption or an attack on the plist parser.
    private static let registrySizeLimit = 1_048_576

    private var lockURL: URL {
        registryURL.deletingLastPathComponent()
            .appending(path: registryURL.lastPathComponent + ".lock")
    }

    /// Runs `body` holding an exclusive `flock` on the sibling lock file.
    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: registryURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let descriptor = open(lockURL.path(percentEncoded: false), O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw WineEngineError.registryCorrupted("Could not open registry lock: \(lockURL.path)")
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw WineEngineError.registryCorrupted("Could not lock engine registry")
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// Reads the registry without locking (callers hold the lock or only read).
    /// Only a genuinely absent file is an empty registry; every other read
    /// failure — permission denied, I/O errors, a directory in the file's
    /// place — or any schema violation fails closed with
    /// ``WineEngineError/registryCorrupted`` so a later mutation can never
    /// overwrite a registry it could not read.
    private func readRegistry() throws -> Registry {
        let data: Data
        do {
            data = try Data(contentsOf: registryURL)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoSuchFileError {
                return Registry(version: Self.registryVersion, engines: [])
            }
            throw WineEngineError.registryCorrupted(
                "Wine engine registry cannot be read: \(error.localizedDescription)"
            )
        }
        guard data.count <= Self.registrySizeLimit else {
            throw WineEngineError.registryCorrupted(
                "Wine engine registry exceeds the size limit: \(registryURL.path)"
            )
        }
        guard let registry = try? JSONDecoder().decode(Registry.self, from: data) else {
            throw WineEngineError.registryCorrupted(
                "Wine engine registry is malformed: \(registryURL.path)"
            )
        }
        try Self.validate(registry)
        return registry
    }

    /// Fails closed on any record the writer could not have produced: wrong
    /// schema version, empty fields, the reserved managed id, non-absolute
    /// paths, or duplicated ids/canonical roots.
    private static func validate(_ registry: Registry) throws {
        func corrupted(_ detail: String) -> WineEngineError {
            .registryCorrupted("Wine engine registry is invalid: \(detail)")
        }
        guard registry.version == Self.registryVersion else {
            throw corrupted("unsupported version \(registry.version)")
        }
        var ids = Set<String>()
        var roots = Set<String>()
        for record in registry.engines {
            guard !record.id.isEmpty, !record.path.isEmpty else {
                throw corrupted("record with an empty id or path")
            }
            guard record.id != WineEngine.managedID else {
                throw corrupted("reserved engine id '\(WineEngine.managedID)'")
            }
            guard record.path.hasPrefix("/") else {
                throw corrupted("non-absolute engine path '\(record.path)'")
            }
            guard ids.insert(record.id).inserted else {
                throw corrupted("duplicate engine id '\(record.id)'")
            }
            let canonical = URL(fileURLWithPath: record.path)
                .resolvingSymlinksInPath().standardizedFileURL
                .path(percentEncoded: false)
            guard roots.insert(canonical).inserted else {
                throw corrupted("duplicate engine path '\(record.path)'")
            }
        }
    }

    private func writeRegistry(_ registry: Registry) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try DurableAtomicFile.write(encoder.encode(registry), to: registryURL)
    }

    // MARK: - Reads

    /// Every engine: the managed one first, then each registered tree
    /// re-detected. Records whose detection fails are still listed, with
    /// ``WineEngine/availabilityError`` set — they stay registered so a moved
    /// tree restored later starts working again.
    public func list() -> [WineEngine] {
        lock.lock()
        defer { lock.unlock() }
        var engines = [WineEngine.managed]
        do {
            for record in try readRegistry().engines where record.id != WineEngine.managedID {
                engines.append(descriptor(for: record))
            }
            lastLoadErrorStorage = nil
        } catch let error as WineEngineError {
            lastLoadErrorStorage = error
        } catch {
            lastLoadErrorStorage = .registryCorrupted(error.localizedDescription)
        }
        return engines
    }

    /// Resolves an engine id to a freshly detected descriptor.
    ///
    /// `managed` always resolves; a registered id re-runs detection and throws
    /// the detection error when the tree is missing or no longer valid;
    /// anything else throws ``WineEngineError/unknownEngine(_:)`` — callers
    /// must surface it, never fall back to the managed engine silently.
    public func resolve(id: String) throws -> WineEngine {
        if id == WineEngine.managedID {
            return .managed
        }
        lock.lock()
        defer { lock.unlock() }
        let registry = try readRegistry()
        guard let record = registry.engines.first(where: { $0.id == id }) else {
            throw WineEngineError.unknownEngine(
                "No Wine engine is registered with id '\(id)'"
            )
        }
        return try WineEngine.detect(at: URL(fileURLWithPath: record.path), id: record.id, name: record.name)
    }

    /// Descriptor for a record: fresh detection, or an unavailable stub that
    /// keeps the registration's identity and carries the rejection reason.
    private func descriptor(for record: Record) -> WineEngine {
        let url = URL(fileURLWithPath: record.path)
        do {
            return try WineEngine.detect(at: url, id: record.id, name: record.name)
        } catch {
            let reason = (error as? WineEngineError)?.errorDescription ?? error.localizedDescription
            let root = url.resolvingSymlinksInPath().standardizedFileURL
            let bin = root.appending(path: "bin")
            return WineEngine(
                id: record.id,
                name: record.name,
                rootURL: root,
                wineBinary: bin.appending(path: "wine64"),
                wineserverBinary: bin.appending(path: "wineserver"),
                libraryURL: root.appending(path: "lib"),
                librariesURL: nil,
                isManaged: false,
                fingerprint: "",
                architectures: [],
                availabilityError: reason,
                version: nil
            )
        }
    }

    // MARK: - Mutations

    /// Registers the external engine at `url` after static detection.
    ///
    /// The canonical (symlink-resolved) root deduplicates registrations:
    /// pointing at an already-registered tree renames the existing record and
    /// re-detects it rather than adding a second id for the same files.
    ///
    /// - Returns: The detected descriptor (its id is stable across calls).
    @discardableResult
    public func register(at url: URL, name: String? = nil) throws -> WineEngine {
        lock.lock()
        defer { lock.unlock() }
        let engine = try WineEngine.detect(at: url, name: name)
        let canonical = engine.rootURL.path(percentEncoded: false)
        return try withExclusiveLock {
            var registry = try readRegistry()
            if let existing = registry.engines.firstIndex(where: {
                URL(fileURLWithPath: $0.path)
                    .resolvingSymlinksInPath().standardizedFileURL
                    .path(percentEncoded: false) == canonical
            }) {
                if let name, !name.isEmpty {
                    registry.engines[existing].name = name
                    try writeRegistry(registry)
                }
                let record = registry.engines[existing]
                return try WineEngine.detect(at: url, id: record.id, name: record.name)
            }
            let record = Record(
                id: UUID().uuidString,
                name: name ?? engine.name,
                path: canonical
            )
            registry.engines.append(record)
            try writeRegistry(registry)
            return try WineEngine.detect(at: url, id: record.id, name: record.name)
        }
    }

    /// Removes a registration. The engine's files are never touched — this
    /// only drops the record.
    ///
    /// - Throws: ``WineEngineError/managedImmutable`` for the managed engine,
    ///   ``WineEngineError/engineInUse(_:)`` while a registered container still
    ///   binds the engine (reassign it first), or
    ///   ``WineEngineError/unknownEngine(_:)`` for an id not in the registry.
    public func remove(id: String) throws {
        try remove(id: id, referencedBy: nil)
    }

    /// Removes a registration, checking references against `referencedBy`
    /// when given (the bridge passes the ids its workspace reports) instead
    /// of the shared-registry provider.
    public func remove(id: String, referencedBy references: Set<String>?) throws {
        guard id != WineEngine.managedID else { throw WineEngineError.managedImmutable }
        lock.lock()
        defer { lock.unlock() }
        let referenced = references ?? referencedEngineIDs()
        guard !referenced.contains(id) else {
            throw WineEngineError.engineInUse(
                "Engine '\(id)' is still selected by a registered container"
            )
        }
        try withExclusiveLock {
            var registry = try readRegistry()
            guard let index = registry.engines.firstIndex(where: { $0.id == id }) else {
                throw WineEngineError.unknownEngine(
                    "No Wine engine is registered with id '\(id)'"
                )
            }
            registry.engines.remove(at: index)
            try writeRegistry(registry)
        }
    }

    /// Engine ids bound by bottles in the shared registry — the default
    /// ``referencedEngineIDs`` provider.
    private static func defaultReferencedEngineIDs() -> Set<String> {
        let registry = BottleData()
        var ids = Set<String>()
        for path in registry.paths {
            let metadata = path.appending(path: "Metadata").appendingPathExtension("plist")
            guard let data = try? Data(contentsOf: metadata),
                  let settings = try? PropertyListDecoder().decode(BottleSettings.self, from: data)
            else { continue }
            let id = settings.wineEngineID
            if id != WineEngine.managedID {
                ids.insert(id)
            }
        }
        return ids
    }
}
