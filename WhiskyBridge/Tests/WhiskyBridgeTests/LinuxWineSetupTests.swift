//
//  LinuxWineSetupTests.swift
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
import Testing
@testable import WhiskyApplication
import WhiskyBridgeProtocol

@Suite("Linux Wine release installation")
struct LinuxWineSetupTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WHISKY_TEST_WINE_RELEASE"] == "1"))
    @MainActor func linuxWinePublishedReleaseDownloadsAndInstalls() async throws {
        let fixture = try WineSetupFixture()
        defer { fixture.cleanup() }
        let service = LinuxWineSetupService(
            root: fixture.service.root, jobs: fixture.jobs, python: fixture.python,
            download: LinuxWineSetupService.download
        )
        let installed = try await fixture.finish(service.call("setup.install", params: [:]), timeout: 600)
        #expect(installed.object?["status"] == .string("completed"))
        #expect(service.status().object?["installed"] == .bool(true))
        let metadata = try #require(service.installed())
        #expect(LinuxWineRelease.validHash(metadata.sha256))
        let runtime = try #require(service.runtimeURL)
        #expect(FileManager.default.isExecutableFile(atPath: runtime.appendingPathComponent("run").path))
        if let evidence = ProcessInfo.processInfo.environment["WHISKY_WINE_TEST_EVIDENCE"] {
            try JSONEncoder().encode(installed).write(to: URL(fileURLWithPath: evidence), options: .atomic)
        }
    }

    @Test func linuxWineVersionsUseNumericOrderingAndPlatformTags() throws {
        #expect(LinuxWineVersion("v0.1.6-linux-amd64")?.description == "0.1.6")
        let newer = try #require(LinuxWineVersion("v0.10.0"))
        let older = try #require(LinuxWineVersion("v0.9.99"))
        #expect(newer > older)
        #expect(LinuxWineVersion("v0.1.6-macos") == nil)
        #expect(LinuxWineVersion("1.2") == nil)
    }

    @Test func linuxWineSelectsCompleteLinuxPrereleasesAndChecksAssetOrigin() throws {
        func release(_ tag: String, draft: Bool = false, linux: Bool = true) -> [String: Any] {
            let prefix = "https://github.com/\(LinuxWineRelease.repository)/releases/download/\(tag)/"
            return [
                "tag_name": tag,
                "draft": draft,
                "prerelease": true,
                "assets": (linux ? LinuxWineRelease.required : ["Libraries.tar.gz"]).map { name in
                    [
                        "name": name,
                        "state": "uploaded",
                        "size": 100,
                        "browser_download_url": prefix + name
                    ]
                }
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            release("v99.0.0", linux: false),
            release("v10.0.0-linux-amd64", draft: true),
            release("v0.9.9-linux-amd64"),
            release("v0.10.0-linux-amd64")
        ])
        let selected = try LinuxWineRelease.select(data)
        #expect(selected.version?.description == "0.10.0")
        #expect(try selected.asset(LinuxWineRelease.archiveName, endpoint: LinuxWineRelease.endpoint).size == 100)
        let poisoned = try JSONDecoder().decode(LinuxWineRelease.self, from: JSONSerialization.data(withJSONObject: [
            "tag_name": "v1.0.0", "draft": false, "assets": [[
                "name": LinuxWineRelease.archiveName,
                "size": 100,
                "state": "uploaded",
                "browser_download_url": "https://example.com/runtime.tar.gz"
            ]]
        ]))
        #expect(throws: BridgeFailure.self) { try poisoned.asset(
            LinuxWineRelease.archiveName,
            endpoint: LinuxWineRelease.endpoint
        ) }
        #expect(throws: BridgeFailure.self) { try LinuxWineRelease.checksums(Data("broken  runtime\n".utf8)) }
    }

    @Test(.enabled(if: WineSetupFixture
            .archiveTestsEnabled)) @MainActor func linuxWineInstallUpdateAndRestartKeepOldGeneration() async throws {
        let fixture = try WineSetupFixture()
        defer { fixture.cleanup() }
        #expect(fixture.service.status().object?["installed"] == .bool(false))
        #expect(fixture.service.status().object?["path"]?.string == fixture.service.root
            .appendingPathComponent("current").path)
        try await fixture.prepare("v0.1.6-linux-amd64")
        let check = try await fixture.finish(fixture.service.call("setup.checkUpdate", params: [:]))
        #expect(check.object?["result"]?.object?["updateAvailable"] == .bool(true))
        let first = try await fixture.finish(fixture.service.call("setup.install", params: [:]))
        #expect(first.object?["status"] == .string("completed"))
        #expect(first.object?["result"]?.object?["version"] == .string("0.1.6"))
        let old = try #require(fixture.service.runtimeURL)
        let host = try #require(LinuxWineHost(runtimeURL: fixture.service.root.appendingPathComponent("current")))
        #expect(host.runtimeURL == old)
        #expect(host.process(host.loader, arguments: [], prefix: fixture.directory).executableURL == old
            .appendingPathComponent("run"))
        try await fixture.prepare("v0.1.7-linux-amd64")
        let updated = try await fixture.finish(fixture.service.call("setup.install", params: [:]))
        #expect(updated.object?["status"] == .string("completed"))
        #expect(fixture.service.runtimeURL != old)
        #expect(FileManager.default.isExecutableFile(atPath: old.appendingPathComponent("bin/wine").path))
        #expect(host.runtimeURL == old)
        let restarted = LinuxWineSetupService(root: fixture.service.root, jobs: BridgeJobStore())
        #expect(restarted.status().object?["version"] == .string("0.1.7"))
        try await fixture.prepare("v0.1.6-linux-amd64")
        let downgrade = try await fixture.finish(fixture.service.call("setup.install", params: ["force": .bool(true)]))
        #expect(downgrade.object?["result"]?.object?["version"] == .string("0.1.7"))
    }

    @Test(.enabled(if: WineSetupFixture
            .archiveTestsEnabled)) @MainActor func linuxWineBadDownloadsAndTraversalPreserveInstalledRuntime(
    ) async throws {
        let fixture = try WineSetupFixture()
        defer { fixture.cleanup() }
        try await fixture.prepare("v0.1.6-linux-amd64")
        #expect(try await fixture.finish(fixture.service.call("setup.install", params: [:]))
            .object?["status"] == .string("completed"))
        let original = fixture.service.runtimeURL
        try await fixture.prepare("v0.1.7-linux-amd64", corrupt: true)
        let corrupt = try await fixture.finish(fixture.service.call("setup.install", params: [:]))
        #expect(corrupt.object?["error"]?.object?["code"] == .string("checksum_mismatch"))
        #expect(fixture.service.runtimeURL == original)
        try await fixture.prepare("v0.1.7-linux-amd64", traversal: true)
        let traversal = try await fixture.finish(fixture.service.call("setup.install", params: [:]))
        #expect(traversal.object?["error"]?.object?["code"] == .string("invalid_archive"))
        #expect(fixture.service.runtimeURL == original)
        #expect(!FileManager.default.fileExists(atPath: fixture.service.root.appendingPathComponent("escaped").path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.service.root.path)
        #expect(!leftovers.contains(where: { $0.hasPrefix(".install-") }))
    }

    @Test @MainActor func linuxWineOfflineAndUpdatePreferencePreventNetwork() async throws {
        let fixture = try WineSetupFixture()
        defer { fixture.cleanup() }
        _ = try fixture.preferences.call(
            "preferences.set",
            params: ["key": .string("checkWhiskyWineUpdates"), "value": .bool(false)]
        )
        let disabled = try await fixture.finish(fixture.service.call("setup.checkUpdate", params: [:]))
        #expect(disabled.object?["result"]?.object?["updateAvailable"] == .bool(false))
        _ = try fixture.preferences.call(
            "preferences.set",
            params: ["key": .string("offlineMode"), "value": .bool(true)]
        )
        let offline = try await fixture.finish(fixture.service.call("setup.install", params: [:]))
        #expect(offline.object?["error"]?.object?["code"] == .string("offline"))
        let check = try await fixture.finish(fixture.service.call("setup.checkUpdate", params: [:]))
        #expect(check.object?["result"]?.object?["updateAvailable"] == .bool(false))
        #expect(await fixture.transport.calls == 0)
    }

    @Test @MainActor func linuxWineCancellationAndConcurrentHelpersKeepCurrentStable() async throws {
        let fixture = try WineSetupFixture()
        defer { fixture.cleanup() }
        try await fixture.prepare("v0.1.6-linux-amd64")
        await fixture.transport.hold(true)
        let job = try fixture.service.call("setup.install", params: [:])
        for _ in 0 ..< 200 {
            if await fixture.transport.archiveStarted {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await fixture.transport.archiveStarted)
        let other = LinuxWineSetupService(
            root: fixture.service.root,
            jobs: fixture.jobs,
            python: fixture.python,
            download: { try await fixture.transport.fetch($0, to: $1, limit: $2) }
        )
        let busy = try await fixture.finish(other.call("setup.install", params: [:]))
        #expect(busy.object?["error"]?.object?["code"] == .string("busy"))
        _ = try fixture.jobs.call("jobs.cancel", params: ["jobID": #require(job.object?["jobID"])])
        #expect(try await fixture.finish(job).object?["status"] == .string("cancelled"))
        #expect(fixture.service.runtimeURL == nil)
    }

    @Test @MainActor func linuxWineExternalRuntimeKeepsInstallerUnavailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("external-wine-\(UUID())")
        let service = LinuxWineSetupService(root: root, externalRuntime: root, jobs: BridgeJobStore())
        #expect(service.methods == ["setup.status"])
        #expect(throws: BridgeFailure.self) { try service.call("setup.install", params: [:]) }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test(.enabled(if: WineSetupFixture
            .archiveTestsEnabled)) @MainActor func linuxWineBusyRecheckBeforeActivationPreservesCurrent() async throws {
        let fixture = try WineSetupFixture()
        defer { fixture.cleanup() }
        try await fixture.prepare("v0.1.6-linux-amd64")
        _ = try await fixture.finish(fixture.service.call("setup.install", params: [:]))
        let current = fixture.service.runtimeURL
        try await fixture.prepare("v0.1.7-linux-amd64")
        var checks = 0
        let operation = try fixture.service.call("setup.install", params: [:]) {
            checks += 1
            if checks == 2 {
                throw BridgeFailure("runtime_busy", "Fixture Wine became active")
            }
        }
        let result = try await fixture.finish(operation)
        #expect(checks == 2)
        #expect(result.object?["error"]?.object?["code"] == .string("runtime_busy"))
        #expect(fixture.service.runtimeURL == current)
    }

    @Test(.enabled(if: WineSetupFixture
            .archiveTestsEnabled)) @MainActor func linuxWineManagedUpdateTakesPriorityOverPreservedBundledFallback(
    ) async throws {
        let fixture = try WineSetupFixture()
        defer { fixture.cleanup() }
        try await fixture.prepare("v0.1.6-linux-amd64")
        _ = try await fixture.finish(fixture.service.call("setup.install", params: [:]))
        let bundled = try #require(fixture.service.runtimeURL)
        let service = LinuxWineSetupService(
            root: fixture.directory.appendingPathComponent("New managed runtime"), fallbackRuntime: bundled,
            jobs: fixture.jobs, python: fixture.python,
            download: { try await fixture.transport.fetch($0, to: $1, limit: $2) }
        )
        #expect(service.runtimeURL == bundled && service.methods.contains("setup.install"))
        #expect(LinuxWineSetupService
            .bundledRuntime(environment: ["WHISKY_WINE_FALLBACK_RUNTIME": bundled.path])?.path == bundled.path)
        try await fixture.prepare("v0.1.7-linux-amd64")
        let installed = try await fixture.finish(service.call("setup.install", params: [:]))
        #expect(installed.object?["result"]?.object?["restartRequired"] == .bool(true))
        #expect(service.runtimeURL != bundled)
        #expect(FileManager.default.fileExists(atPath: bundled.path))
        let current = try await fixture.finish(service.call("setup.install", params: [:]))
        #expect(current.object?["result"]?.object?["restartRequired"] == .bool(false))
    }
}
