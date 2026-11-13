//
//  LinuxWineEngine.swift
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

/// Feature identifier shared with the macOS `wine.engines` wire schema and
/// `EngineFeatureDto`.
public enum LinuxWineEngineFeature: String, Codable, CaseIterable, Sendable {
    case dxvk
    case dxmt
    case d3dMetal
    case esync
    case msync
    case avx
    case gdiUpscaling
    case gdiCoreML
    case metal
    case metalFX
    case frameGeneration
    case shadowImportedHostMemory
    case dxvkAsync
}

public enum LinuxWineEngineFeatureState: String, Codable, Sendable {
    case supported
    case unverified
    case unavailable
}

public struct LinuxWineEngineFeatureStatus: Codable, Sendable, Equatable {
    public let feature: LinuxWineEngineFeature
    public let state: LinuxWineEngineFeatureState
    public let reason: String?
    public let canOverride: Bool

    public init(
        feature: LinuxWineEngineFeature,
        state: LinuxWineEngineFeatureState,
        reason: String? = nil,
        canOverride: Bool = false
    ) {
        self.feature = feature
        self.state = state
        self.reason = reason
        self.canOverride = canOverride
    }
}

public enum LinuxWineEngineError: LocalizedError, Sendable, Equatable {
    case notFound(URL)
    case notDirectory(URL)
    case invalidLayout(URL)
    case missingLoader(URL)
    case missingWineserver(URL)
    case missingLibraryDirectory(URL)
    case invalidBinary(URL)
    case architectureMismatch(loader: String, wineserver: String)
    case unsupportedArchitecture(String)

    public var errorDescription: String? {
        switch self {
        case let .notFound(url):
            "No engine tree exists at \(url.path)"
        case let .notDirectory(url):
            "Expected a directory for the Wine engine at \(url.path)"
        case let .invalidLayout(url):
            "Unsupported Wine engine layout at \(url.path)"
        case let .missingLoader(url):
            "Missing executable Wine loader at \(url.path)"
        case let .missingWineserver(url):
            "Missing executable wineserver at \(url.path)"
        case let .missingLibraryDirectory(url):
            "Missing Wine library directory at \(url.path)"
        case let .invalidBinary(url):
            "Expected a native ELF executable at \(url.path)"
        case let .architectureMismatch(loader, wineserver):
            "Wine loader (\(loader)) and wineserver (\(wineserver)) architectures do not match"
        case let .unsupportedArchitecture(arch):
            "Unsupported ELF architecture \(arch) for Linux Wine engine"
        }
    }
}

/// Static Linux counterpart to WhiskyKit's `WineEngine`: inspects a Wine runtime
/// directory purely from ELF headers and layout metadata without ever executing
/// binaries inside the tree.
public struct LinuxWineEngine: Identifiable, Codable, Sendable, Equatable {
    public static let managedID = "managed"

    public let id: String
    public let name: String
    public let rootURL: URL
    public let runtimeURL: URL
    public let managed: Bool
    public let available: Bool
    public let error: String?
    public let version: String?
    public let architectures: [String]
    public let fingerprint: String?
    public let translation: String?
    public let features: [LinuxWineEngineFeatureStatus]

    public var isManaged: Bool { managed }
    public var isAvailable: Bool { available }

    public init(
        id: String,
        name: String,
        rootURL: URL,
        runtimeURL: URL,
        managed: Bool,
        available: Bool,
        error: String? = nil,
        version: String? = nil,
        architectures: [String] = [],
        fingerprint: String? = nil,
        translation: String? = nil,
        features: [LinuxWineEngineFeatureStatus] = []
    ) {
        self.id = id
        self.name = name
        self.rootURL = rootURL
        self.runtimeURL = runtimeURL
        self.managed = managed
        self.available = available
        self.error = error
        self.version = version
        self.architectures = architectures
        self.fingerprint = fingerprint
        self.translation = translation
        self.features = features
    }

    public func makeHost(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LinuxWineHost? {
        LinuxWineHost(runtimeURL: runtimeURL, environment: environment)
    }

    public func featureStatus(_ feature: LinuxWineEngineFeature) -> LinuxWineEngineFeatureStatus {
        features.first { $0.feature == feature }
            ?? LinuxWineEngineFeatureStatus(feature: feature, state: .unavailable, reason: "Unknown feature")
    }

    public func featureEnabled(_ feature: LinuxWineEngineFeature, overrides: [String: String]) -> Bool {
        let status = featureStatus(feature)
        switch status.state {
        case .supported:
            return true
        case .unavailable:
            return false
        case .unverified:
            guard status.canOverride,
                  let fingerprint, !fingerprint.isEmpty
            else { return false }
            return overrides[feature.rawValue] == fingerprint
        }
    }

    public func effectiveState(
        for feature: LinuxWineEngineFeature,
        overrides: [String: String]
    ) -> (state: LinuxWineEngineFeatureState, reason: String?, canOverride: Bool, enabled: Bool) {
        let status = featureStatus(feature)
        return (status.state, status.reason, status.canOverride, featureEnabled(feature, overrides: overrides))
    }

    public func fieldPolicy(overrides: [String: String]) -> [String: JSONValue] {
        func unrestricted() -> JSONValue {
            .object([
                "disabled": .bool(false),
                "state": .string(LinuxWineEngineFeatureState.supported.rawValue),
                "canOverride": .bool(false)
            ])
        }
        func policy(for feature: LinuxWineEngineFeature) -> JSONValue {
            let eff = effectiveState(for: feature, overrides: overrides)
            var dict: [String: JSONValue] = [
                "disabled": .bool(!eff.enabled),
                "state": .string(eff.state.rawValue),
                "canOverride": .bool(eff.canOverride),
                "feature": .string(feature.rawValue)
            ]
            if let reason = eff.reason {
                dict["reason"] = .string(reason)
            }
            return .object(dict)
        }
        return [
            "enhancedSync": .object([
                "disabled": .bool(false),
                "choices": .object([
                    "none": unrestricted(),
                    "fsync": unrestricted(),
                    "esync": policy(for: .esync)
                ])
            ]),
            "graphicsBackend": .object([
                "disabled": .bool(false),
                "choices": .object([
                    "recommended": unrestricted(),
                    "wined3d": unrestricted(),
                    "dxvk": policy(for: .dxvk)
                ])
            ]),
            "dxvkAsync": policy(for: .dxvkAsync)
        ]
    }

    public func record() -> JSONValue {
        var dict: [String: JSONValue] = [
            "id": .string(id),
            "name": .string(name),
            "path": .string(rootURL.path),
            "managed": .bool(managed),
            "available": .bool(available),
            "architectures": .array(architectures.map(JSONValue.string)),
            "features": .array(features.map { status in
                .object([
                    "id": .string(status.feature.rawValue),
                    "state": .string(status.state.rawValue),
                    "reason": status.reason.map(JSONValue.string) ?? .null,
                    "canOverride": .bool(status.canOverride)
                ])
            })
        ]
        if let error { dict["error"] = .string(error) }
        if let version { dict["version"] = .string(version) }
        if let fingerprint { dict["fingerprint"] = .string(fingerprint) }
        if let translation { dict["translation"] = .string(translation) }
        return .object(dict)
    }

    // MARK: - Detection

    public static func detect(
        id: String,
        name: String? = nil,
        at rawURL: URL,
        managed: Bool = false,
        version: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> LinuxWineEngine {
        let resolvedRoot = rawURL.resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.fileExists(atPath: resolvedRoot.path) else {
            throw LinuxWineEngineError.notFound(resolvedRoot)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw LinuxWineEngineError.notDirectory(resolvedRoot)
        }
        if resolvedRoot.pathExtension.lowercased() == "app" {
            throw LinuxWineEngineError.invalidLayout(resolvedRoot)
        }

        let runtimeURL = try normalizeRuntimeURL(under: resolvedRoot)
        guard let loader = LinuxWineHost.resolveLoader(in: runtimeURL) else {
            throw LinuxWineEngineError.missingLoader(runtimeURL.appendingPathComponent("bin/wine"))
        }
        let wineserver = runtimeURL.appendingPathComponent("bin/wineserver")
        guard FileManager.default.isExecutableFile(atPath: wineserver.path) else {
            throw LinuxWineEngineError.missingWineserver(wineserver)
        }
        guard hasLibraryDirectory(in: runtimeURL) else {
            throw LinuxWineEngineError.missingLibraryDirectory(runtimeURL.appendingPathComponent("lib"))
        }

        guard let loaderELF = LinuxWineHost.inspectELF(loader), loaderELF.isExecutableType else {
            throw LinuxWineEngineError.invalidBinary(loader)
        }
        guard let serverELF = LinuxWineHost.inspectELF(wineserver), serverELF.isExecutableType else {
            throw LinuxWineEngineError.invalidBinary(wineserver)
        }
        guard let loaderArch = loaderELF.architecture else {
            throw LinuxWineEngineError.unsupportedArchitecture("unknown")
        }
        guard let serverArch = serverELF.architecture else {
            throw LinuxWineEngineError.unsupportedArchitecture("unknown")
        }
        guard compatibleArchitectures(loader: loaderArch, wineserver: serverArch) else {
            throw LinuxWineEngineError.architectureMismatch(loader: loaderArch, wineserver: serverArch)
        }

        var architectures = [serverArch]
        if loaderArch != serverArch, !architectures.contains(loaderArch) {
            architectures.append(loaderArch)
        }

        guard let host = LinuxWineHost(runtimeURL: runtimeURL, environment: environment) else {
            throw LinuxWineEngineError.missingLoader(loader)
        }
        let detectedVersion = version ?? staticVersion(at: runtimeURL)
        let fingerprint = computeFingerprint(runtimeURL: runtimeURL, loader: loader, wineserver: wineserver)
        let resolvedName = normalizedName(name, fallbackURL: resolvedRoot)

        return LinuxWineEngine(
            id: id,
            name: resolvedName,
            rootURL: resolvedRoot,
            runtimeURL: runtimeURL,
            managed: managed,
            available: host.canExecute,
            error: host.unavailableReason,
            version: detectedVersion,
            architectures: architectures,
            fingerprint: fingerprint,
            translation: host.translationDescription,
            features: featureStatuses(managed: managed)
        )
    }

    public static func managedDescriptor(
        runtimeURL: URL?,
        isExternalPinned: Bool = false,
        installedVersion: String? = nil,
        defaultPath: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LinuxWineEngine {
        guard let runtimeURL else {
            return LinuxWineEngine(
                id: managedID,
                name: "Whisky Wine",
                rootURL: defaultPath,
                runtimeURL: defaultPath,
                managed: true,
                available: false,
                error: "The managed Wine runtime is not installed",
                features: featureStatuses(managed: true)
            )
        }
        if let detected = try? detect(
            id: managedID,
            name: "Whisky Wine",
            at: runtimeURL,
            managed: true,
            version: installedVersion,
            environment: environment
        ) {
            return detected
        }
        // Preserve test fixtures using shell scripts for the managed runtime when explicit runtime URLs exist.
        if let host = LinuxWineHost(runtimeURL: runtimeURL, environment: environment) {
            let resolved = runtimeURL.resolvingSymlinksInPath().standardizedFileURL
            let fingerprint = computeFingerprint(runtimeURL: resolved, loader: host.loader, wineserver: host.wineserver)
            let archs = host.architecture == "unknown" ? [] : [host.architecture]
            return LinuxWineEngine(
                id: managedID,
                name: "Whisky Wine",
                rootURL: resolved,
                runtimeURL: resolved,
                managed: true,
                available: host.canExecute,
                error: host.unavailableReason,
                version: installedVersion,
                architectures: archs,
                fingerprint: fingerprint,
                translation: host.translationDescription,
                features: featureStatuses(managed: true)
            )
        }
        let message = isExternalPinned
            ? "The configured Wine runtime is unavailable"
            : "The managed Wine runtime is unavailable"
        return LinuxWineEngine(
            id: managedID,
            name: "Whisky Wine",
            rootURL: runtimeURL,
            runtimeURL: runtimeURL,
            managed: true,
            available: false,
            error: message,
            version: installedVersion,
            features: featureStatuses(managed: true)
        )
    }

    public static func featureStatuses(managed: Bool) -> [LinuxWineEngineFeatureStatus] {
        LinuxWineEngineFeature.allCases.map { feature in
            switch feature {
            case .esync:
                if managed {
                    return LinuxWineEngineFeatureStatus(feature: feature, state: .supported)
                }
                return LinuxWineEngineFeatureStatus(
                    feature: feature,
                    state: .unverified,
                    reason: "External engines are not verified for ESync support; confirm before enabling if tested.",
                    canOverride: true
                )
            case .dxvk:
                if managed {
                    return LinuxWineEngineFeatureStatus(feature: feature, state: .supported)
                }
                return LinuxWineEngineFeatureStatus(
                    feature: feature,
                    state: .unverified,
                    reason: "External engines are not verified for DXVK; confirm before enabling once DXVK is tested in this container.",
                    canOverride: true
                )
            case .dxvkAsync:
                if managed {
                    return LinuxWineEngineFeatureStatus(feature: feature, state: .supported)
                }
                return LinuxWineEngineFeatureStatus(
                    feature: feature,
                    state: .unverified,
                    reason: "External engines are not verified for DXVK Async; confirm before enabling.",
                    canOverride: true
                )
            case .dxmt, .d3dMetal, .msync, .avx, .gdiUpscaling, .gdiCoreML,
                 .metal, .metalFX, .frameGeneration, .shadowImportedHostMemory:
                return LinuxWineEngineFeatureStatus(
                    feature: feature,
                    state: .unavailable,
                    reason: "Not supported on Linux",
                    canOverride: false
                )
            }
        }
    }

    private static func normalizeRuntimeURL(under root: URL) throws -> URL {
        for candidate in [root, root.appendingPathComponent("Wine")] {
            let bin = candidate.appendingPathComponent("bin")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: bin.path, isDirectory: &isDir), isDir.boolValue {
                return candidate.resolvingSymlinksInPath().standardizedFileURL
            }
        }
        throw LinuxWineEngineError.missingLoader(root.appendingPathComponent("bin/wine"))
    }

    private static func hasLibraryDirectory(in runtimeURL: URL) -> Bool {
        for candidate in ["lib", "lib64"] {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(
                atPath: runtimeURL.appendingPathComponent(candidate).path,
                isDirectory: &isDir
            ), isDir.boolValue {
                return true
            }
        }
        return false
    }

    private static func compatibleArchitectures(loader: String, wineserver: String) -> Bool {
        if loader == wineserver {
            return true
        }
        // Classic split 32/64 Wine trees pair an i386 `wine` loader with an x86_64 `wineserver`.
        return loader == "i386" && wineserver == "x86_64"
    }

    private static func normalizedName(_ raw: String?, fallbackURL: URL) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return String(trimmed.prefix(128))
        }
        let folder = fallbackURL.lastPathComponent
        return folder.isEmpty ? "Wine Engine" : folder
    }

    private static func staticVersion(at runtimeURL: URL) -> String? {
        struct ReleaseMeta: Decodable { let version: String? }
        for candidate in [
            runtimeURL.deletingLastPathComponent().appendingPathComponent("release.json"),
            runtimeURL.appendingPathComponent("release.json")
        ] {
            guard let data = try? Data(contentsOf: candidate), data.count <= 65_536,
                  let parsed = try? JSONDecoder().decode(ReleaseMeta.self, from: data),
                  let version = parsed.version?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !version.isEmpty
            else { continue }
            return version
        }
        let versionFile = runtimeURL.appendingPathComponent("VERSION")
        if let text = try? String(contentsOf: versionFile, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed.count <= 64 {
                return trimmed
            }
        }
        return nil
    }

    private static func computeFingerprint(runtimeURL: URL, loader: URL, wineserver: URL) -> String {
        var components = [runtimeURL.path]
        let markers = [
            loader,
            runtimeURL.appendingPathComponent("bin/wine64"),
            wineserver,
            runtimeURL.appendingPathComponent("run"),
            runtimeURL.appendingPathComponent("release.json"),
            runtimeURL.deletingLastPathComponent().appendingPathComponent("release.json")
        ]
        for marker in markers {
            guard let values = try? marker.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize,
                  let modified = values.contentModificationDate
            else { continue }
            let nanos = Int64((modified.timeIntervalSince1970 * 1_000_000_000).rounded())
            components.append("\(marker.lastPathComponent):\(size):\(nanos)")
        }
        return LibraryStorageLayout.sha256(Data(components.joined(separator: "\n").utf8))
    }
}

/// Non-blocking POSIX `flock` lease serializing launches (`shared`) against
/// engine rebinding and confirmation mutations (`exclusive`) across processes.
public final class LinuxWineEngineLease: @unchecked Sendable {
    private var descriptor: Int32?

    private init(_ descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        release()
    }

    public func release() {
        guard let descriptor else { return }
        self.descriptor = nil
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    public static func acquireShared(engineID: String, locksDirectory: URL) throws -> LinuxWineEngineLease {
        try acquire(engineID: engineID, locksDirectory: locksDirectory, exclusive: false)
    }

    public static func acquireExclusive(engineID: String, locksDirectory: URL) throws -> LinuxWineEngineLease {
        try acquire(engineID: engineID, locksDirectory: locksDirectory, exclusive: true)
    }

    public static func lockFileURL(for engineID: String, in locksDirectory: URL) -> URL {
        let key = engineID == LinuxWineEngine.managedID
            ? "managed"
            : String(LibraryStorageLayout.sha256(Data(engineID.utf8)).prefix(16))
        return locksDirectory.appendingPathComponent("\(key).lock")
    }

    private static func acquire(
        engineID: String,
        locksDirectory: URL,
        exclusive: Bool
    ) throws -> LinuxWineEngineLease {
        try FileManager.default.createDirectory(at: locksDirectory, withIntermediateDirectories: true)
        let lockURL = lockFileURL(for: engineID, in: locksDirectory)
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            let err = errno
            close(fd)
            if err == EWOULDBLOCK || err == EAGAIN {
                throw BridgeFailure(
                    "engine_busy",
                    "This Wine engine or container is in use by another operation",
                    retryable: true
                )
            }
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        return LinuxWineEngineLease(fd)
    }
}
