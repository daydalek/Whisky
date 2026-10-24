//
//  LinuxWineSetupService+Install.swift
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

extension LinuxWineSetupService {
    func install(
        _ remote: Remote,
        progress: BridgeJobStore.Progress,
        beforeActivate: @MainActor () async throws -> Void
    ) async throws -> JSONValue {
        let manager = FileManager.default
        let stage = root.appendingPathComponent(".install-\(UUID())", isDirectory: true)
        try manager.createDirectory(
            at: stage,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? manager.removeItem(at: stage) }
        let archive = stage.appendingPathComponent("download.tar.gz")
        progress(.object(["stage": .string("downloading")]))
        try requireNetwork()
        try await download(remote.archive.browserDownloadURL, archive, remote.archive.size)
        let archiveSize = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        guard Int64(archiveSize) == remote.archive.size else {
            throw BridgeFailure("download_failed", "Wine archive download is incomplete")
        }
        progress(.object(["stage": .string("verifying")]))
        let payload = stage.appendingPathComponent("payload")
        try manager.createDirectory(at: payload, withIntermediateDirectories: false)
        _ = try await archiveTool(["extract", archive.path, payload.path, remote.sha256])
        try Task.checkCancellation()
        try await beforeActivate()
        try requireNetwork()
        try Task.checkCancellation()
        progress(.object(["stage": .string("installing")]))
        guard let version = remote.release.version else {
            throw BridgeFailure("invalid_manifest", "The Linux Wine release has an invalid version")
        }
        let installed = Installed(
            version: version,
            sha256: remote.sha256,
            tag: remote.release.tagName,
            validationMode: remote.manifest.validationMode
        )
        try activate(installed, payload: payload, stage: stage)
        var result = status().object ?? [:]
        result["restartRequired"] = .bool(true)
        return .object(result)
    }

    private func activate(_ installed: Installed, payload: URL, stage: URL) throws {
        let manager = FileManager.default
        try JSONEncoder().encode(installed).write(to: payload.appendingPathComponent("release.json"), options: .atomic)
        let versions = root.appendingPathComponent("versions", isDirectory: true)
        try manager.createDirectory(at: versions, withIntermediateDirectories: true)
        let name = "\(installed.version)-\(installed.sha256.prefix(12))-\(UUID())"
        let destination = versions.appendingPathComponent(name)
        try manager.moveItem(at: payload, to: destination)
        var activated = false
        defer {
            if !activated {
                try? manager.removeItem(at: destination)
            }
        }
        let current = root.appendingPathComponent("current")
        if manager.fileExists(atPath: current.path),
           (try? manager.destinationOfSymbolicLink(atPath: current.path)) == nil {
            throw BridgeFailure("unmanaged_runtime", "The managed Wine current path contains an external directory")
        }
        let link = stage.appendingPathComponent("current")
        try manager.createSymbolicLink(atPath: link.path, withDestinationPath: "versions/\(name)/wine-linux-amd64")
        guard rename(link.path, current.path) == 0 else { throw POSIXError(.EIO) }
        activated = true
    }

    func archiveTool(_ arguments: [String]) async throws -> String {
        guard let script = Bundle.module.url(forResource: "linux-wine-archive", withExtension: "py") else {
            throw BridgeFailure("install_failed", "The Wine archive validation helper is missing")
        }
        let result = try await HostCommand.run(
            executable: python,
            arguments: [script.path] + arguments,
            environment: ProcessInfo.processInfo.environment,
            timeout: 300
        )
        let output = String(data: result.output, encoding: .utf8) ?? ""
        guard result.status == 0, !result.signalled else {
            throw BridgeFailure(
                result.status == 3 ? "checksum_mismatch" : "invalid_archive",
                "Wine archive validation failed: \(output.prefix(500))"
            )
        }
        return output
    }

    nonisolated static func download(_ url: URL, to destination: URL, limit: Int64) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        request.setValue("Whisky-Linux-Wine", forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BridgeFailure(
                "download_failed",
                "Wine download returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
            )
        }
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max
        guard size <= limit else { throw BridgeFailure("download_failed", "Wine download exceeds its size limit") }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}
