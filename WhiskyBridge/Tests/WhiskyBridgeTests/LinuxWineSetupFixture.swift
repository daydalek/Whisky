//
//  LinuxWineSetupFixture.swift
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

actor WineFixtureTransport {
    var responses: [URL: Data] = [:]
    var calls = 0
    var holdArchive = false
    var archiveStarted = false
    func replace(_ values: [URL: Data]) {
        responses = values
    }

    func hold(_ value: Bool) {
        holdArchive = value
    }

    func fetch(_ url: URL, to path: URL, limit: Int64) async throws {
        calls += 1
        if url.lastPathComponent == LinuxWineRelease.archiveName {
            archiveStarted = true
            while holdArchive {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        guard let data = responses[url] else { throw URLError(.fileDoesNotExist) }
        guard data.count <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        try Task.checkCancellation()
        try data.write(to: path)
    }
}

@MainActor
final class WineSetupFixture {
    nonisolated static var archiveTestsEnabled: Bool {
        #if os(Linux)
        true
        #else
        ProcessInfo.processInfo.environment["WHISKY_TEST_PYTHON"] != nil
        #endif
    }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wine-updater-\(UUID())")
    let transport = WineFixtureTransport()
    let jobs = BridgeJobStore()
    let preferences: PreferencesService
    let service: LinuxWineSetupService
    let python: URL

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        let paths = (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":")
        python = environment["WHISKY_TEST_PYTHON"].map { URL(fileURLWithPath: $0) }
            ?? paths.map { URL(fileURLWithPath: String($0)).appendingPathComponent("python3") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
            ?? URL(fileURLWithPath: "/usr/bin/python3")
        preferences = PreferencesService(
            fileURL: directory.appendingPathComponent("preferences.plist"),
            defaultBottleDirectory: directory.appendingPathComponent("Bottles")
        )
        let transport = transport
        service = LinuxWineSetupService(
            root: directory.appendingPathComponent("Runtime 包 $HOME 'literal'"),
            jobs: jobs,
            preferences: preferences,
            python: python,
            download: { try await transport.fetch($0, to: $1, limit: $2) }
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    func archive(traversal: Bool) async throws -> Data {
        let archive = directory.appendingPathComponent("fixture.tar.gz")
        let script = """
        import io,tarfile,sys
        with tarfile.open(sys.argv[1], 'w:gz') as tf:
            for name in ('bin/wine','bin/wineserver','run'):
                value = bytearray(64)
                value[:6] = b'\\x7fELF\\x02\\x01'
                value[18:20] = b'\\x3e\\x00'
                if name == 'run': value = b'#!/bin/sh\\nexit 0\\n'
                entry = tarfile.TarInfo('wine-linux-amd64/' + name)
                entry.size = len(value)
                entry.mode = 0o755
                tf.addfile(entry, io.BytesIO(value))
            if sys.argv[2] == 'true':
                entry = tarfile.TarInfo('wine-linux-amd64/../../escaped')
                entry.size = 1
                tf.addfile(entry, io.BytesIO(b'x'))
        """
        let result = try await HostCommand.run(
            executable: python,
            arguments: ["-c", script, archive.path, String(traversal)],
            environment: ProcessInfo.processInfo.environment,
            timeout: 10
        )
        #expect(result.status == 0)
        return try Data(contentsOf: archive)
    }

    func prepare(_ tag: String, corrupt: Bool = false, traversal: Bool = false) async throws {
        let bytes = try await archive(traversal: traversal)
        let hash = try await sha256(bytes)
        let manifest: [String: Any] = [
            "runtime_asset": LinuxWineRelease.archiveName,
            "prefix_architecture": "win64",
            "target": "Ubuntu 24.04 x86_64",
            "validation_mode": "compile-only",
            "entrypoints": [
                "wine": "run",
                "loader": "bin/wine",
                "wineserver": "bin/wineserver"
            ]
        ]
        let metadata = try JSONSerialization.data(withJSONObject: manifest)
        let sums = try await Data(
            "\(hash)  \(LinuxWineRelease.archiveName)\n\(sha256(metadata))  linux-release-manifest.json\n"
                .utf8
        )
        let prefix = "https://github.com/\(LinuxWineRelease.repository)/releases/download/\(tag)/"
        let assets: [(String, Data)] = [
            (LinuxWineRelease.archiveName, bytes),
            ("linux-release-manifest.json", metadata),
            ("SHA256SUMS-linux-amd64", sums)
        ]
        var responses: [URL: Data] = [:]
        for (name, data) in assets {
            try responses[#require(URL(string: prefix + name))] = data
        }
        if corrupt {
            try responses[#require(URL(string: prefix + LinuxWineRelease.archiveName))] = Data(
                repeating: 0,
                count: bytes.count
            )
        }
        let release: [String: Any] = [
            "tag_name": tag,
            "draft": false,
            "prerelease": true,
            "assets": assets.map { name, data in
                [
                    "name": name,
                    "state": "uploaded",
                    "size": data.count,
                    "browser_download_url": prefix + name
                ]
            }
        ]
        responses[LinuxWineRelease.endpoint] = try JSONSerialization.data(withJSONObject: [release])
        await transport.replace(responses)
    }

    func sha256(_ data: Data) async throws -> String {
        let path = directory.appendingPathComponent("hash-input-\(UUID())")
        try data.write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let result = try await HostCommand.run(
            executable: python,
            arguments: [
                "-c",
                "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())",
                path.path
            ],
            environment: ProcessInfo.processInfo.environment,
            timeout: 10
        )
        #expect(result.status == 0)
        return try #require(String(data: result.output, encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func finish(_ start: JSONValue, timeout: TimeInterval = 10) async throws -> JSONValue {
        let id = try #require(start.object?["jobID"]?.string)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            let value = try jobs.call("jobs.get", params: ["jobID": .string(id)])
            if ["completed", "failed", "cancelled"].contains(value.object?["status"]?.string ?? "") {
                return value
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Wine setup job timed out")
        return .null
    }
}
