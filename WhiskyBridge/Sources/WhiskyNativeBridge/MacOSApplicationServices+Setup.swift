//
//  MacOSApplicationServices+Setup.swift
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

import Foundation
import WhiskyApplication
import WhiskyBridgeProtocol
import WhiskyCore
import WhiskyKit

// MARK: - WhiskyWine runtime setup

extension MacOSApplicationServices {
    /// `setup.status` answers immediately; `setup.install` downloads the
    /// published runtime in a job so the helper stays responsive.
    func setupCall(
        _ method: String,
        params: [String: JSONValue]
    ) async throws -> JSONValue {
        switch method {
        case "setup.status":
            return self.setupStatus()
        case "setup.gptk.status":
            return await Task.detached(priority: .utility) {
                // Status reads stand in for the old settings page's task:
                // a runtime install clears Libraries and takes a deployed
                // payload with it, so the store redeploys here.
                GPTKImporter.deployStoredPayloadIfCapable()
                return Self.gptkStatus()
            }.value
        case "setup.gptk.import":
            let url = try params.path("path")
            return try await Task.detached(priority: .userInitiated) {
                var mountsToDetach: [URL] = []
                defer {
                    for mount in mountsToDetach.reversed() {
                        GPTKDiskImage.detach(mount)
                    }
                }
                do {
                    let resolved = try GPTKDiskImage.resolvePayload(at: url)
                    mountsToDetach = resolved.mounts
                    let payload = try GPTKImporter.validatePayload(at: resolved.libRoot)
                    _ = try GPTKImporter.importPayload(payload)
                    if GPTKImporter.isRuntimeGPTKCapable() {
                        try GPTKImporter.deployStoredPayload()
                    }
                    return Self.gptkStatus()
                } catch {
                    throw BridgeFailure("import_failed", error.localizedDescription)
                }
            }.value
        case "setup.gptk.remove":
            return try await Task.detached(priority: .userInitiated) {
                try GPTKImporter.removeDeployedPayload()
                try GPTKImporter.removeStore()
                return Self.gptkStatus()
            }.value
        case "setup.checkUpdate":
            // `shouldUpdateWhiskyWine` reads the shared `checkWhiskyWineUpdates`
            // default, so the frontend's persisted toggle is honoured here.
            return try jobs.start(name: "setup.checkUpdate") {
                $0(.object(["stage": .string("checking")]))
                let result = await WhiskyWineInstaller.shouldUpdateWhiskyWine()
                return .object([
                    "updateAvailable": .bool(result.0),
                    "remoteVersion": .string(String(result.1)),
                    "localVersion": WhiskyWineInstaller.whiskyWineVersion()
                        .map { JSONValue.string(String($0)) } ?? .null
                ])
            }
        case "setup.installRosetta":
            return try jobs.start(name: "setup.installRosetta") { progress in
                progress(.object(["stage": .string("rosetta")]))
                let installed = try await Rosetta2.installRosetta()
                guard installed else {
                    throw BridgeFailure("install_failed", "Rosetta 2 installation did not complete")
                }
                return .object(["installed": .bool(true)])
            }
        case "setup.install":
            return try await installWineRuntime(params: params)
        default:
            throw BridgeFailure("method_unavailable", "Native method is unavailable")
        }
    }

    /// Downloads, verifies and installs the published Wine runtime in a job so
    /// progress events keep flowing to the frontend.
    private func installWineRuntime(params: [String: JSONValue]) async throws -> JSONValue {
        try jobs.start(name: "setup.install") { progress in
            progress(.object(["stage": .string("checking")]))
            let manifest = try await DistributionConfig.fetchWineManifest(useCache: false)
            let url = try DistributionConfig.librariesURL(for: manifest)

            // Skip the download when the installed runtime is already current.
            let force = params["force"].map {
                if case .bool(true) = $0 {
                    true
                } else {
                    false
                }
            } ?? false
            if !force, WhiskyWineInstaller.isWhiskyWineInstalled(),
               let local = WhiskyWineInstaller.whiskyWineVersion(), !(local < manifest.version) {
                // A current runtime can still hold no GPTK payload when
                // Libraries was replaced outside this path.
                await Task.detached(priority: .utility) {
                    _ = GPTKImporter.deployStoredPayloadIfCapable()
                }.value
                return self.setupStatus()
            }

            // A previously fetched archive whose hash still verifies
            // skips the download entirely.
            var archive = await Self.reusableArchive(sha256: manifest.sha256)
            if archive == nil {
                progress(.object(["stage": .string("downloading")]))
                archive = try await Self.downloadArchive(from: url) { received, total in
                    progress(.object([
                        "stage": .string("downloading"),
                        "received": .integer(received),
                        "total": .integer(total)
                    ]))
                }
            }
            guard let archive else {
                throw BridgeFailure("download_failed", "Wine runtime download produced no archive")
            }
            if let expected = manifest.sha256 {
                progress(.object(["stage": .string("verifying")]))
                // Hashed off the main actor — the archive is well over a
                // hundred megabytes.
                let matches = await Task.detached(priority: .userInitiated) {
                    WhiskyWineInstaller.sha256(ofFileAt: archive) == expected
                }.value
                guard matches else {
                    ResumableDownloader.discardArtifacts(at: archive)
                    throw BridgeFailure(
                        "checksum_mismatch",
                        "Downloaded Wine runtime failed its SHA-256 check"
                    )
                }
            }

            progress(.object(["stage": .string("installing")]))
            // Extraction is synchronous and can take a while; keep the
            // helper's actor free so `jobs.get` keeps answering.
            let installed = try await Task.detached(priority: .userInitiated) {
                try WhiskyWineInstaller.install(from: archive)
                WhiskyWineInstaller.cleanupTarball(at: archive)
                let installed = WhiskyWineInstaller.isWhiskyWineInstalled()
                if installed {
                    // The install replaced Libraries, so any deployed GPTK
                    // payload went with it; the store outlives it and
                    // redeploys here.
                    GPTKImporter.deployStoredPayloadIfCapable()
                }
                return installed
            }.value
            guard installed else {
                throw BridgeFailure(
                    "install_failed",
                    "The Wine runtime was extracted but is not usable"
                )
            }
            return self.setupStatus()
        }
    }

    /// Where the runtime archive is cached. A stable location lets
    /// interrupted downloads resume across retries and relaunches.
    private nonisolated static var archiveDestination: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: Bundle.whiskyBundleIdentifier)
            .appending(path: "RuntimeDownload")
            .appending(path: "Libraries.tar.gz")
    }

    /// Returns the cached archive when its SHA-256 still matches the manifest;
    /// clears a stale one so the next download starts clean.
    private nonisolated static func reusableArchive(sha256 expected: String?) async -> URL? {
        let archive = archiveDestination
        guard let expected,
              FileManager.default.fileExists(atPath: archive.path(percentEncoded: false))
        else { return nil }
        let matches = await Task.detached(priority: .userInitiated) {
            WhiskyWineInstaller.sha256(ofFileAt: archive) == expected
        }.value
        if matches {
            return archive
        }
        ResumableDownloader.discardArtifacts(at: archive)
        return nil
    }

    /// Downloads the archive to disk, resuming interrupted transfers and
    /// retrying transient failures. Runs off the main actor so a saturated
    /// connection can't starve other requests; byte progress hops onto the
    /// main actor at most a few times per second.
    private nonisolated static func downloadArchive(
        from url: URL,
        progress: @escaping @MainActor @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        let destination = archiveDestination
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 60
        let downloader = ResumableDownloader(sessionConfiguration: config)
        let gate = ProgressReportGate()
        do {
            try await downloader.download(from: url, to: destination, progress: { update in
                guard gate.shouldReport() else { return }
                let received = update.bytesOnDisk
                let total = update.expectedBytes ?? 0
                Task { @MainActor in progress(received, total) }
            })
        } catch let ResumableDownloadError.httpStatus(code) {
            throw BridgeFailure("download_failed", "Wine runtime download returned HTTP \(code)")
        }
        let size = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        await progress(size, size)
        return destination
    }

    private func setupStatus() -> JSONValue {
        let installed = WhiskyWineInstaller.isWhiskyWineInstalled()
        let version = WhiskyWineInstaller.whiskyWineVersion().map { version in
            "\(version.major).\(version.minor).\(version.patch)"
        }
        // Registered external engines count toward "a usable Wine exists":
        // containers bound to them work without the managed runtime, so the
        // UI must not force the managed install flow on their account.
        let externalUsable = engineStore.list().contains {
            !$0.isManaged && $0.isAvailable
        }
        return .object([
            "installed": .bool(installed),
            "managedInstalled": .bool(installed),
            "anyEngineAvailable": .bool(installed || externalUsable),
            "version": version.map(JSONValue.string) ?? .null,
            "path": .string(WhiskyWineInstaller.applicationFolder.path),
            "rosettaInstalled": .bool(Rosetta2.isRosettaInstalled),
            "appleSilicon": .bool(HostArchitecture.isAppleSilicon)
        ])
    }

    private nonisolated static func gptkStatus() -> JSONValue {
        let record = GPTKImporter.storedRecord()
        let capable = GPTKImporter.isRuntimeGPTKCapable()
        let deployed = GPTKImporter.isDeployed()
        var unverified = false
        var failureReason: String?
        if record != nil {
            let verdict = GPTKImporter.verifyStoredPayload()
            if case let .failed(reason) = verdict {
                unverified = true
                failureReason = reason
            }
        }
        return .object([
            "installed": .bool(record != nil),
            "version": record.map { JSONValue.string($0.gptkVersion) } ?? .null,
            "deployed": .bool(deployed),
            "capable": .bool(capable),
            "unverified": .bool(unverified),
            "error": failureReason.map(JSONValue.string) ?? .null
        ])
    }
}

/// Rate-limits download progress hops onto the main actor: `shouldReport()`
/// returns `true` at most four times per second.
private final class ProgressReportGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastReport = Date.distantPast

    func shouldReport(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard now.timeIntervalSince(lastReport) > 0.25 else { return false }
        lastReport = now
        return true
    }
}
