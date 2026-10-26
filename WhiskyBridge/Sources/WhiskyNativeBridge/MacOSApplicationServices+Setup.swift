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
            return Self.setupStatus()
        case "setup.gptk.status":
            return Self.gptkStatus()
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
            return try jobs.start(name: "setup.install") { progress in
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
                    return Self.setupStatus()
                }

                progress(.object(["stage": .string("downloading")]))
                let archive = try await Self.downloadArchive(from: url) { received, total in
                    progress(.object([
                        "stage": .string("downloading"),
                        "received": .integer(received),
                        "total": .integer(total)
                    ]))
                }
                if let expected = manifest.sha256 {
                    progress(.object(["stage": .string("verifying")]))
                    guard WhiskyWineInstaller.sha256(ofFileAt: archive) == expected else {
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
                    return WhiskyWineInstaller.isWhiskyWineInstalled()
                }.value
                guard installed else {
                    throw BridgeFailure(
                        "install_failed",
                        "The Wine runtime was extracted but is not usable"
                    )
                }
                return Self.setupStatus()
            }
        default:
            throw BridgeFailure("method_unavailable", "Native method is unavailable")
        }
    }

    /// Streams the archive to a temporary file, reporting byte progress at
    /// most a few times per second.
    private static func downloadArchive(
        from url: URL,
        progress: @escaping @MainActor @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw BridgeFailure("download_failed", "Wine runtime download returned HTTP \(http.statusCode)")
        }
        let total = max(response.expectedContentLength, 0)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhiskyWine-\(UUID().uuidString).tar.gz")
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var received: Int64 = 0
        var lastReport = Date.distantPast
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 1 << 20 {
                    try handle.write(contentsOf: buffer)
                    received += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    try Task.checkCancellation()
                    if Date().timeIntervalSince(lastReport) > 0.25 {
                        lastReport = Date()
                        await progress(received, total)
                    }
                }
            }
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
            await progress(received, total)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return destination
    }

    private static func setupStatus() -> JSONValue {
        let installed = WhiskyWineInstaller.isWhiskyWineInstalled()
        let version = WhiskyWineInstaller.whiskyWineVersion().map { version in
            "\(version.major).\(version.minor).\(version.patch)"
        }
        return .object([
            "installed": .bool(installed),
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
