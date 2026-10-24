//
//  LinuxWineSetupService.swift
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
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Published Linux assets are installed as immutable generations. `current` is
/// replaced atomically; running processes keep their resolved generation path.
@MainActor
public final class LinuxWineSetupService {
    typealias Download = @Sendable (URL, URL, Int64) async throws -> Void
    struct Installed: Codable {
        let version: LinuxWineVersion
        let sha256: String
        let tag: String
        let validationMode: String?
    }

    struct Remote {
        let release: LinuxWineRelease
        let archive: LinuxWineReleaseAsset
        let sha256: String
        let manifest: LinuxWinePackageManifest
    }

    let root: URL
    let externalRuntime: URL?
    let fallbackRuntime: URL?
    let jobs: BridgeJobStore
    let preferences: PreferencesService?
    let endpoint: URL
    let python: URL
    let download: Download

    public convenience init(
        root: URL = LinuxWineSetupService.defaultRoot(),
        externalRuntime: URL? = nil,
        fallbackRuntime: URL? = nil,
        jobs: BridgeJobStore,
        preferences: PreferencesService? = nil,
        releasesURL: URL? = nil
    ) {
        self.init(
            root: root,
            externalRuntime: externalRuntime,
            fallbackRuntime: fallbackRuntime,
            jobs: jobs,
            preferences: preferences,
            endpoint: releasesURL ?? LinuxWineRelease.endpoint,
            python: URL(fileURLWithPath: "/usr/bin/python3"),
            download: Self.download
        )
    }

    init(
        root: URL,
        externalRuntime: URL? = nil,
        fallbackRuntime: URL? = nil,
        jobs: BridgeJobStore,
        preferences: PreferencesService? = nil,
        endpoint: URL = LinuxWineRelease.endpoint,
        python: URL = URL(fileURLWithPath: "/usr/bin/python3"),
        download: @escaping Download
    ) {
        self.root = root
        self.externalRuntime = externalRuntime
        self.fallbackRuntime = fallbackRuntime
        self.jobs = jobs
        self.preferences = preferences
        self.endpoint = endpoint
        self.python = python
        self.download = download
    }

    public static func defaultRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base = environment["XDG_DATA_HOME"].flatMap {
            $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        return base.appendingPathComponent("whisky/runtime/wine", isDirectory: true)
    }

    public static func bundledRuntime(
        executable: URL? = Bundle.main.executableURL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let path = environment["WHISKY_WINE_FALLBACK_RUNTIME"], path.hasPrefix("/") {
            let url = URL(fileURLWithPath: path)
            return LinuxWineHost(runtimeURL: url) == nil ? nil : url.resolvingSymlinksInPath()
        }
        guard let directory = executable?.deletingLastPathComponent() else { return nil }
        return ["../../wine", "../wine"].map { directory.appendingPathComponent($0).resolvingSymlinksInPath() }
            .first { LinuxWineHost(runtimeURL: $0) != nil }
    }

    public var runtimeURL: URL? {
        if let externalRuntime {
            return externalRuntime.resolvingSymlinksInPath()
        }
        let current = root.appendingPathComponent("current").resolvingSymlinksInPath()
        guard current.path.hasPrefix(root.resolvingSymlinksInPath().appendingPathComponent("versions").path + "/"),
              LinuxWineHost(runtimeURL: current) != nil, installed() != nil
        else {
            return fallbackRuntime.flatMap { url in
                LinuxWineHost(runtimeURL: url) == nil ? nil : url.resolvingSymlinksInPath()
            }
        }
        return current
    }

    public var methods: [String] {
        ["setup.status"] + (externalRuntime == nil ? ["setup.checkUpdate", "setup.install"] : [])
    }

    func installed() -> Installed? {
        let current = root.appendingPathComponent("current").resolvingSymlinksInPath()
        let metadata = current.deletingLastPathComponent().appendingPathComponent("release.json")
        guard current.path.hasPrefix(root.resolvingSymlinksInPath().appendingPathComponent("versions").path + "/"),
              LinuxWineHost(runtimeURL: current) != nil, let data = try? Data(contentsOf: metadata)
        else { return nil }
        return try? JSONDecoder().decode(Installed.self, from: data)
    }

    public func status() -> JSONValue {
        let host = runtimeURL.flatMap { LinuxWineHost(runtimeURL: $0) }
        return .object([
            "installed": .bool(host != nil),
            "restartRequired": .bool(false),
            "version": (externalRuntime == nil ? installed() : nil).map { .string($0.version.description) } ?? .null,
            "path": .string(runtimeURL?.path ?? root.appendingPathComponent("current").path),
            "managed": .bool(externalRuntime == nil),
            "canExecute": .bool(host?.canExecute == true),
            "translation": host.map { .string($0.translationDescription) } ?? .null,
            "runtimeArchitecture": host.map { .string($0.architecture) } ?? .null,
            "rosettaInstalled": .bool(true), "appleSilicon": .bool(false)
        ])
    }

    public func call(
        _ method: String,
        params: [String: JSONValue],
        beforeInstall: @escaping @MainActor () async throws -> Void = {}
    ) throws -> JSONValue {
        if method == "setup.status" {
            return status()
        }
        guard externalRuntime == nil, methods.contains(method) else {
            throw BridgeFailure("method_unavailable", "This Wine runtime is managed externally")
        }
        let force = params["force"] == nil ? false : try params.flag("force")
        return try jobs.start(name: method) { [self] progress in
            let values = try preferences?.call("preferences.read", params: [:]).object
            if method == "setup.checkUpdate",
               values?["offlineMode"] == .bool(true) || values?["checkWhiskyWineUpdates"] == .bool(false) {
                return updateResult(remote: nil)
            }
            try requireNetwork()
            progress(.object(["stage": .string("checking")]))
            if method == "setup.checkUpdate" {
                return try await updateResult(remote: remote())
            }
            let lease = try acquireLock()
            defer { _ = flock(lease, LOCK_UN)
                _ = close(lease)
            }
            let remote = try await remote()
            if let local = installed(), let version = remote.release.version,
               local.version >= version {
                guard local.version != version || local.sha256 == remote.sha256 else {
                    throw BridgeFailure("version_conflict", "A changed Wine archive requires an increased version")
                }
                if local.version > version || !force {
                    return status()
                }
            }
            try await beforeInstall()
            return try await install(remote, progress: progress, beforeActivate: beforeInstall)
        }
    }

    private func updateResult(remote: Remote?) -> JSONValue {
        let local = installed()?.version
        let version = remote?.release.version
        return .object([
            "updateAvailable": .bool(version.map { remote in local.map { $0 < remote } ?? true } ?? false),
            "remoteVersion": .string(version?.description ?? local?.description ?? "0.0.0"),
            "localVersion": local.map { .string($0.description) } ?? .null
        ])
    }

    func requireNetwork() throws {
        let values = try preferences?.call("preferences.read", params: [:])
        guard values?.object?["offlineMode"] != .bool(true) else {
            throw BridgeFailure("offline", "Wine downloads are disabled by offline mode")
        }
        guard endpoint == LinuxWineRelease.endpoint || LinuxWineRelease.isLoopback(endpoint) else {
            throw BridgeFailure("invalid_manifest", "Unsupported Linux Wine release endpoint")
        }
    }

    private func acquireLock() throws -> Int32 {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let descriptor = open(root.appendingPathComponent("install.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EACCES) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = close(descriptor)
            throw BridgeFailure("busy", "Another helper is installing Wine", retryable: true)
        }
        return descriptor
    }

    private func fetch(_ url: URL, limit: Int64) async throws -> Data {
        try requireNetwork()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wine-metadata-\(UUID())")
        defer { try? FileManager.default.removeItem(at: file) }
        try await download(url, file, limit)
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max
        guard size <= limit else { throw BridgeFailure("invalid_manifest", "Wine metadata exceeds its size limit") }
        return try Data(contentsOf: file)
    }

    private func remote() async throws -> Remote {
        let release = try await LinuxWineRelease.select(fetch(endpoint, limit: 4_194_304))
        let archive = try release.asset(LinuxWineRelease.archiveName, endpoint: endpoint)
        let manifestAsset = try release.asset("linux-release-manifest.json", endpoint: endpoint)
        let sumsAsset = try release.asset("SHA256SUMS-linux-amd64", endpoint: endpoint)
        let sumsData = try await fetch(sumsAsset.browserDownloadURL, limit: 1_048_576)
        let sums = try LinuxWineRelease.checksums(sumsData)
        guard let hash = sums[archive.name], let manifestHash = sums[manifestAsset.name],
              archive.digest == nil || archive.digest == "sha256:" + hash
        else { throw BridgeFailure("checksum_mismatch", "Wine checksums disagree with release assets") }
        let data = try await fetch(manifestAsset.browserDownloadURL, limit: 1_048_576)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wine-manifest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file)
        let digest = try await archiveTool(["digest", file.path])
        guard digest.trimmingCharacters(in: .whitespacesAndNewlines) == manifestHash else {
            throw BridgeFailure("checksum_mismatch", "Wine package manifest failed its SHA-256 check")
        }
        let manifest = try JSONDecoder().decode(LinuxWinePackageManifest.self, from: data)
        try manifest.validate()
        return Remote(release: release, archive: archive, sha256: hash, manifest: manifest)
    }
}
