//
//  LinuxParityTests.swift
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
import WhiskyCore

private struct ParityFixture {
    let root: URL
    let runtime: URL
    let bottle: URL
    let host: LinuxWineHost

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("linux-parity-\(UUID())")
        runtime = root.appendingPathComponent("runtime")
        bottle = root.appendingPathComponent("Bottle")
        try FileManager.default.createDirectory(
            at: runtime.appendingPathComponent("bin"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: bottle.appendingPathComponent("drive_c/windows/system32"),
            withIntermediateDirectories: true
        )
        let loader = #"""
        printf '%s\n' "$@" >> "$WINEPREFIX/commands"
        case "$1" in
          reg)
            for file in "$WINEPREFIX"/drive_c/whisky-config-*.reg; do cp "$file" "$WINEPREFIX/imported.reg"; done
            exit "$(cat "$WINEPREFIX/reg-status" 2>/dev/null || echo 0)";;
          tasklist.exe)
            cat "$WINEPREFIX/tasklist.csv" 2>/dev/null
            exit "$(cat "$WINEPREFIX/query-status" 2>/dev/null || echo 0)";;
          taskkill.exe) exit 7;;
          winecfg) exit 0;;
          *) echo started > "$WINEPREFIX/program-started"; exec sleep 30;;
        esac
        """#
        let server = #"""
        printf '%s\n' "$@" >> "$WINEPREFIX/server-commands"
        case "$1" in
          -k0) exit "$(cat "$WINEPREFIX/server-status" 2>/dev/null || echo 0)";;
          -k) touch "$WINEPREFIX/killed"; exit "$(cat "$WINEPREFIX/kill-status" 2>/dev/null || echo 0)";;
          -w) exit 0;;
        esac
        """#
        for (name, contents) in [("wine", loader), ("wineserver", server)] {
            let url = runtime.appendingPathComponent("bin/" + name)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        host = try #require(LinuxWineHost(
            runtimeURL: runtime,
            environment: ["WHISKY_WINE_EMULATOR": "/bin/sh", "PATH": "/usr/bin:/bin"]
        ))
        try metadata([:])
    }

    func metadata(_ values: [String: Any], in container: URL? = nil) throws {
        let folder = container ?? bottle
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var raw = values
        raw["info"] = ["name": "Test", "pins": [], "blocklist": []]
        try PropertyListSerialization.data(fromPropertyList: raw, format: .xml, options: 0)
            .write(to: folder.appendingPathComponent("Metadata.plist"))
    }

    func write(_ file: String, _ value: String) throws {
        try value.write(to: bottle.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    func entry(_ name: String, launcher: LauncherType? = nil) throws -> LibraryEntry {
        let exe = bottle.appendingPathComponent("drive_c/" + name)
        try Data("MZ".utf8).write(to: exe)
        return LibraryEntry(
            id: name,
            name: name,
            iconURL: nil,
            bottleURL: bottle,
            source: .pinned,
            launch: .program(exe),
            launcher: launcher
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Linux production wiring regressions") @MainActor
struct LinuxParityTests {
    @Test func desktopConfigurationFailurePreservesStoredValue() async throws {
        let fixture = try ParityFixture()
        defer { fixture.cleanup() }
        try fixture.write("reg-status", "7")
        let service = ApplicationService(
            workspace: .init(containers: [fixture.bottle]),
            native: LinuxApplicationServices(host: fixture.host)
        )
        await #expect(throws: BridgeFailure.self) {
            try await service.call("configuration.set", params: [
                "container": .string(fixture.bottle.path),
                "field": .string("virtualDesktopEnabled"),
                "value": .bool(true)
            ])
        }
        let contents = try Data(contentsOf: fixture.bottle.appendingPathComponent("imported.reg"))
        #expect(contents.prefix(2) == Data([0xFF, 0xFE]))
        #expect(String(data: contents, encoding: .utf16LittleEndian)?.contains("1920x1080") == true)
        let metadata = try ProgramSettingsService.load(fixture.bottle.appendingPathComponent("Metadata.plist"))
        #expect(metadata["displayConfig"] == nil)
        await service.shutdown()
    }

    @Test func registryPreparationRetriesFailureAndUsesNativeAudioGPUValues() async throws {
        let fixture = try ParityFixture()
        defer { fixture.cleanup() }
        try fixture.metadata([
            "audioConfig": ["latencyPreset": "lowLatency"],
            "launcherConfig": ["compatibilityMode": true, "gpuSpoofing": true, "gpuVendor": "NVIDIA"]
        ])
        try fixture.write("reg-status", "9")
        await #expect(throws: BridgeFailure.self) { try await LinuxWineConfiguration.prepare(
            container: fixture.bottle,
            host: fixture.host
        ) }
        #expect(!FileManager.default
            .fileExists(atPath: fixture.bottle.appendingPathComponent(".whisky-linux-launch-registry.json").path))
        try fixture.write("reg-status", "0")
        try await LinuxWineConfiguration.prepare(container: fixture.bottle, host: fixture.host)
        let text = try String(
            contentsOf: fixture.bottle.appendingPathComponent("imported.reg"),
            encoding: .utf16LittleEndian
        )
        #expect(text.contains("\"HelBuflen\"=\"512\""))
        #expect(text.contains("dword:000010de"))
        #expect(text.contains("dword:00002684"))
    }

    @Test func programVirtualDesktopChangesExecutableArguments() throws {
        let config = LinuxLaunchConfiguration.compose(
            values: [:],
            bottleEnvironment: [:],
            bottleDLLOverrides: [],
            program: [
                "arguments": "--flag \"two words\"", "overrides": [
                    "virtualDesktopEnabled": true,
                    "resolutionPreset": "custom",
                    "customResolutionWidth": 1_366,
                    "customResolutionHeight": 768
                ]
            ]
        )
        let args = config.wineArguments(for: URL(fileURLWithPath: "/tmp/My Game/play.exe"))
        #expect(args.first == "explorer")
        #expect(args[1].hasSuffix(",1366x768"))
        #expect(args.suffix(3) == ["/tmp/My Game/play.exe", "--flag", "two words"])
        #expect(throws: BridgeFailure.self) {
            try LinuxWineConfiguration.virtualDesktop([
                "virtualDesktopEnabled": .boolean(true),
                "resolutionPreset": .text("matchDisplay")
            ])
        }
    }

    @Test func processFailuresPropagate() async throws {
        let fixture = try ParityFixture()
        defer { fixture.cleanup() }
        let processes = LinuxWineProcessHost(host: fixture.host)
        await #expect(throws: BridgeFailure.self) { try await processes.terminateProcess(
            in: fixture.bottle,
            pid: 42,
            force: false
        ) }
        try fixture.write("kill-status", "8")
        await #expect(throws: BridgeFailure.self) { try await processes.terminateAllProcesses(in: fixture.bottle) }
        try fixture.write("query-status", "7")
        await #expect(throws: BridgeFailure.self) { try await processes.listProcesses(in: fixture.bottle) }
    }

    @Test func runningStateMatchesEachGameAndHistoryPersists() async throws {
        let fixture = try ParityFixture()
        defer { fixture.cleanup() }
        let gameA = try fixture.entry("a.exe"), gameB = try fixture.entry("b.exe")
        let driver = LinuxWineRuntimeDriver(
            host: fixture.host,
            logDirectory: fixture.root.appendingPathComponent("logs")
        )
        try fixture.write("tasklist.csv", "\"b.exe\",\"42\",\"Console\",\"1\",\"100 K\"\n")
        await driver.configure(entries: [gameA, gameB], containerURL: fixture.bottle)
        driver.stopTracking()
        await driver.poll()
        #expect(driver.snapshot.observation.runningEntryIDs == [gameB.id])
        #expect(!driver.capabilities(for: gameA).contains(.stop))
        try fixture.write("tasklist.csv", "")
        await driver.poll()
        #expect(driver.snapshot.observation.runningEntryIDs.isEmpty)
        let activity = try JSONDecoder().decode(
            GameActivity.self,
            from: Data(contentsOf: LibraryStorageLayout.activity(for: gameB))
        )
        #expect(activity.lastSessionEndedAt != nil)
        #expect(activity.owner == nil)
        let executable = fixture.bottle.appendingPathComponent("drive_c/a.exe")
        let run = try LinuxProgramRunHistory.begin(
            container: fixture.bottle,
            executable: executable,
            logs: fixture.root.appendingPathComponent("logs")
        )
        try run.finish(exitCode: 23)
        let payload = try ProgramHistoryService.call(
            "programs.history.read",
            params: [
                "container": .string(fixture.bottle.path),
                "executable": .string(executable
                    .path)
            ],
            workspace: .init(containers: [fixture.bottle])
        )
        #expect(payload.object?["entries"]?.array?.first?.object?["exitCode"] == .integer(23))
        driver.stopTracking()
    }

    @Test func cancellationLeavesNoRunningStateOrBottleWideKill() async throws {
        let fixture = try ParityFixture()
        defer { fixture.cleanup() }
        let entry = try fixture.entry("sleep.exe")
        let driver = LinuxWineRuntimeDriver(
            host: fixture.host,
            logDirectory: fixture.root.appendingPathComponent("logs")
        )
        let task = Task { await driver.launchProgram(.init(entry: entry), onStarted: {}) }
        for _ in 0 ..< 100 {
            if FileManager.default.fileExists(atPath: fixture.bottle.appendingPathComponent("program-started").path) {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        task.cancel()
        let result = await task.value
        #expect(result.errorDescription != nil)
        #expect(driver.snapshot.observation.runningEntryIDs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.bottle.appendingPathComponent("killed").path))
        driver.stopTracking()
    }

    @Test func exitPolicyHonorsGlobalAndPerBottleSettingsAndReportsFailures() async throws {
        let fixture = try ParityFixture()
        defer { fixture.cleanup() }
        let never = fixture.root.appendingPathComponent("Never")
        let inherited = fixture.root.appendingPathComponent("Inherited")
        try fixture.metadata(["cleanupConfig": ["killOnQuit": "always"]])
        try fixture.metadata(["cleanupConfig": ["killOnQuit": "never"]], in: never)
        try fixture.metadata([:], in: inherited)
        let preferences = PreferencesService(
            fileURL: fixture.root.appendingPathComponent("prefs.plist"),
            defaultBottleDirectory: fixture.root
        )
        _ = try preferences.call("preferences.set", params: ["key": .string("killOnTerminate"), "value": .bool(false)])
        let native = LinuxApplicationServices(
            preferences: preferences,
            shutdownContainers: { [fixture.bottle, never, inherited] },
            host: fixture.host
        )
        try await native.prepareShutdown(applyExitPolicy: false)
        #expect(!FileManager.default.fileExists(atPath: fixture.bottle.appendingPathComponent("killed").path))
        try await native.prepareShutdown(applyExitPolicy: true)
        #expect(FileManager.default.fileExists(atPath: fixture.bottle.appendingPathComponent("killed").path))
        #expect(!FileManager.default.fileExists(atPath: never.appendingPathComponent("killed").path))
        #expect(!FileManager.default.fileExists(atPath: inherited.appendingPathComponent("killed").path))
        _ = try preferences.call("preferences.set", params: ["key": .string("killOnTerminate"), "value": .bool(true)])
        try await native.prepareShutdown(applyExitPolicy: true)
        #expect(FileManager.default.fileExists(atPath: inherited.appendingPathComponent("killed").path))
        try fixture.write("kill-status", "6")
        let service = ApplicationService(workspace: .init(containers: [fixture.bottle]), native: native)
        let response = await service.respond(.init(
            id: "quit",
            method: "bridge.shutdown",
            params: ["applyExitPolicy": .bool(true)]
        ))
        #expect(response.error != nil)
        #expect(await service.respond(.init(id: "retry", method: "bridge.describe")).error == nil)
        await service.shutdown()
    }

    @Test func activityPreservesRatingsAndSkipsLaunchers() throws {
        let fixture = try ParityFixture()
        defer { fixture.cleanup() }
        let entry = try fixture.entry("game.exe")
        let workspace = ApplicationWorkspace(containers: [fixture.bottle])
        _ = try workspace.setRating(8, entry: entry)
        let store = LinuxActivityStore()
        let date = Date()
        try store.sample(entry, seconds: 4, at: date)
        try store.sample(entry, seconds: 0, at: date.addingTimeInterval(1), completed: true)
        let result = try JSONDecoder().decode(
            GameActivity.self,
            from: Data(contentsOf: LibraryStorageLayout.activity(for: entry))
        )
        #expect(result.rating == 8)
        #expect(result.playTime == 4)
        #expect(result.lastSessionEndedAt == date.addingTimeInterval(1))
        let launcher = try fixture.entry("steam.exe", launcher: .steam)
        try store.sample(launcher, seconds: 10, at: date)
        #expect(!FileManager.default.fileExists(atPath: LibraryStorageLayout.activity(for: launcher).path))
    }

    @Test func alreadyCancelledWineCommandNeverSpawns() async throws {
        let fixture = try ParityFixture()
        defer { fixture.cleanup() }
        let task = Task {
            try await fixture.host.run(fixture.host.loader, arguments: ["sleep.exe"], prefix: fixture.bottle)
        }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: fixture.bottle.appendingPathComponent("program-started").path))
    }

    @Test func selectingDXVKRequiresInstalledNativeComponents() async throws {
        let fixture = try ParityFixture()
        defer { fixture.cleanup() }
        try fixture.metadata(["graphicsConfig": ["backend": "dxvk"]])
        await #expect(throws: BridgeFailure.self) {
            try await LinuxLaunchConfiguration.load(container: fixture.bottle, executable: nil)
        }
        for directory in ["system32", "syswow64"] {
            let root = fixture.bottle.appendingPathComponent("drive_c/windows/" + directory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for name in ["d3d11.dll", "dxgi.dll"] {
                try Data("MZ-DXVK-fixture".utf8).write(to: root.appendingPathComponent(name))
            }
        }
        let config = try await LinuxLaunchConfiguration.load(container: fixture.bottle, executable: nil)
        #expect(config.environment["WINEDLLOVERRIDES"]?.contains("d3d11=n,b") == true)
    }

    @Test func linuxSchemaOnlyOffersImplementedOptions() throws {
        let fields = ContainerConfiguration.fields(for: .linux)
        for id in ContainerConfiguration.linuxUnavailableFields {
            #expect(!fields.contains { $0.id == id })
        }
        let sync = try #require(fields.first { $0.id == "enhancedSync" })
        #expect(throws: (any Error).self) { try sync.validate(.text("msync")) }
        let graphics = try #require(fields.first { $0.id == "graphicsBackend" })
        #expect(throws: (any Error).self) { try graphics.validate(.text("d3dMetal")) }
        #expect(ContainerConfiguration.fields(for: .macOS).contains { $0.id == "discordPresence" })
    }
}
