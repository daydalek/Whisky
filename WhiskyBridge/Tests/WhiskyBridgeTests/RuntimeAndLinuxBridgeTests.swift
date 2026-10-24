//
//  RuntimeAndLinuxBridgeTests.swift
//  WhiskyBridge
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

@MainActor
private final class PortableTestDriver: LibraryRuntimeDriver {
    var snapshot = LibraryRuntimeDriverSnapshot()
    private var continuation: AsyncStream<LibraryRuntimeDriverEvent>.Continuation?
    var startedRequests: [LibraryLaunchRequest] = []
    var stoppedEntries: [String] = []

    func events() -> AsyncStream<LibraryRuntimeDriverEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.yield(.changed(self.snapshot))
        }
    }

    func capabilities(for entry: LibraryEntry) -> LibraryRuntimeCapabilities {
        [.launch, .cancelLaunch, .stop, .terminal]
    }

    func retainContainers(_ urls: Set<URL>) {}
    func configure(entries: [LibraryEntry], containerURL: URL) async {}

    func launchProgram(
        _ request: LibraryLaunchRequest,
        onStarted: @escaping @MainActor () -> Void
    ) async -> LaunchResult {
        onStarted()
        return .launchedSuccessfully(programName: request.entry.name)
    }

    func programDidStart(_ request: LibraryLaunchRequest) {
        startedRequests.append(request)
        snapshot.revision &+= 1
        snapshot.observation.runningEntryIDs.insert(request.entry.id)
        continuation?.yield(.changed(snapshot))
    }

    func launchSteam(_ entry: LibraryEntry) {}
    func cancelSteamLaunch(_ entry: LibraryEntry) {}

    func stop(_ entry: LibraryEntry) async {
        stoppedEntries.append(entry.id)
        snapshot.revision &+= 1
        snapshot.observation.runningEntryIDs.remove(entry.id)
        snapshot.observation.endedEntryIDs = [entry.id]
        continuation?.yield(.changed(snapshot))
    }

    func stopTracking() {}
}

@MainActor
private final class TestClipboard: ClipboardAccess {
    var value = ClipboardSnapshot(kind: .text, sizeBytes: 64_000, textPreview: "secret", version: "v1")
    func snapshot() -> ClipboardSnapshot {
        value
    }

    func clear(ifMatches snapshot: ClipboardSnapshot) -> Bool {
        guard value.version == snapshot.version else { return false }
        value = .init(kind: .empty, sizeBytes: 0, version: "v2")
        return true
    }
}

@Suite("Portable runtime, folders and Linux bridge services")
struct RuntimeAndLinuxBridgeTests {
    @Test @MainActor func portableRuntimeServiceDrivesLaunchInteractionAndEvents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whisky-rt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let container = root.appendingPathComponent("Bottle")
        let executable = container.appendingPathComponent("drive_c/Game/play.exe")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x4D, 0x5A]).write(to: executable)
        let metadata: [String: Any] = [
            "info": ["name": "Portable", "pins": [], "blocklist": []],
            "cleanupConfig": ["clipboardPolicy": "warn", "clipboardThreshold": 1_024]
        ]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
            .write(to: container.appendingPathComponent("Metadata.plist"))

        let workspace = ApplicationWorkspace(containers: [container])
        let driver = PortableTestDriver()
        let clipboard = TestClipboard()
        let runtime = RuntimeService(driver: driver, clipboard: { clipboard })
        let service = ApplicationService(workspace: workspace, runtime: runtime)

        _ = try await service.call("programs.pin", params: [
            "container": .string(container.path),
            "executable": .string(executable.path),
            "name": .string("Play"),
            "pinned": .bool(true)
        ])
        let configured = try await service.call("runtime.configure", params: ["container": .string(container.path)])
        let entryID = try #require(configured.object?["entries"]?.arrayValues?.first?.object?["id"]?.string)

        let prompt = try await service.call("runtime.launch", params: [
            "container": .string(container.path),
            "entryID": .string(entryID)
        ])
        #expect(prompt.object?["accepted"] == .bool(false))
        let token = try #require(prompt.object?["interaction"]?.object?["token"]?.string)

        let launched = try await service.call("runtime.launch", params: [
            "container": .string(container.path),
            "entryID": .string(entryID),
            "interactionToken": .string(token),
            "clipboardDecision": .string("clear")
        ])
        #expect(launched.object?["accepted"] == .bool(true))
        #expect(clipboard.value.kind == .empty)

        for _ in 0 ..< 50 where driver.startedRequests.isEmpty {
            await Task.yield()
        }
        #expect(driver.startedRequests.count == 1)

        let events = try await service.call("runtime.events", params: ["after": .string("0")])
        #expect(events.object?["resyncRequired"] == .bool(false))
        let stopped = try await service.call("runtime.stop", params: [
            "container": .string(container.path),
            "entryID": .string(entryID)
        ])
        #expect(stopped.object?["accepted"] == .bool(true))
        #expect(driver.stoppedEntries == [entryID])
        await service.shutdown()
    }

    @Test @MainActor func helperCompositionAdvertisesRuntimeAndSnapshotsWithoutAGame() async throws {
        let runtime = RuntimeService(driver: UnavailableLibraryRuntimeDriver())
        let service = ApplicationService(workspace: ApplicationWorkspace(containers: []), runtime: runtime)

        let describe = await service.respond(.init(id: "1", method: "bridge.describe"))
        let methods = try #require(describe.result?.object?["methods"]?.arrayValues?
            .compactMap { $0.string })
        for method in RuntimeService.methods {
            #expect(methods.contains(method))
        }
        let capabilities = try #require(describe.result?.object?["capabilities"]?.arrayValues?
            .compactMap { $0.string })
        for capability in RuntimeService.capabilities {
            #expect(capabilities.contains(capability))
        }

        let snapshot = await service.respond(.init(id: "2", method: "runtime.snapshot"))
        #expect(snapshot.error == nil)
        #expect(snapshot.result?.object?["sequence"] == .string("0"))
        #expect(snapshot.result?.object?["entries"]?.arrayValues?.isEmpty == true)
        #expect(snapshot.result?.object?["queryFailures"]?.object?.isEmpty == true)

        let events = await service.respond(.init(id: "3", method: "runtime.events", params: [
            "after": .string("0")
        ]))
        #expect(events.error == nil)
        #expect(events.result?.object?["events"]?.arrayValues?.isEmpty == true)
        #expect(events.result?.object?["resyncRequired"] == .bool(false))
        #expect(events.result?.object?["snapshot"]?.object?["sequence"] == .string("0"))
        await service.shutdown()
    }

    @Test @MainActor func foldersBridgeMethodsManageRootsAssignmentsExclusionsAndExecutables() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whisky-folders-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let container = root.appendingPathComponent("Bottle")
        let gamesRoot = container.appendingPathComponent("drive_c/Games")
        let gameFolder = gamesRoot.appendingPathComponent("Touhou")
        let exe = gameFolder.appendingPathComponent("TH06.EXE")
        try FileManager.default.createDirectory(at: gameFolder, withIntermediateDirectories: true)
        try Data([0x4D, 0x5A]).write(to: exe)

        let service = ApplicationService(workspace: ApplicationWorkspace(containers: [container]))
        let added = try await service.call("folders.addRoot", params: [
            "container": .string(container.path),
            "path": .string(gamesRoot.path)
        ])
        #expect(added.object?["roots"]?.arrayValues == [.string(gamesRoot.path)])

        let assigned = try await service.call("folders.assign", params: [
            "container": .string(container.path),
            "path": .string(gameFolder.path),
            "assigned": .bool(true)
        ])
        #expect(assigned.object?["assignedFolders"]?.arrayValues == [.string(gameFolder.path)])

        let bound = try await service.call("folders.executable", params: [
            "container": .string(container.path),
            "path": .string(gameFolder.path),
            "executable": .string(exe.path)
        ])
        #expect(bound.object?["executables"]?.object?[gameFolder.path] == .string(exe.path))

        let entries = try await service.call("library.entries", params: ["container": .string(container.path)])
        #expect(entries.arrayValues?.first?.object?["icon"] == .string(exe.path))
        #expect(entries.arrayValues?.first?.object?["folder"] == .string(gameFolder.path))

        let candidatesFromFile = try await service.call("folders.candidates", params: [
            "container": .string(container.path),
            "path": .string(exe.path)
        ])
        #expect(candidatesFromFile.object?["folder"] == .string(gameFolder.path))

        let excluded = try await service.call("folders.exclude", params: [
            "container": .string(container.path),
            "path": .string(gameFolder.path),
            "excluded": .bool(true)
        ])
        #expect(excluded.object?["excludedFolders"]?.arrayValues == [.string(gameFolder.path)])

        var visibility = LibraryVisibility()
        visibility.hiddenIdentities.insert("program:drive_c/Games/Touhou")
        try visibility.save(bottleURL: container)

        // Re-adding a root clears exclusions and hidden entries under it, as
        // the SwiftUI folder sheet does.
        let addedAgain = try await service.call("folders.addRoot", params: [
            "container": .string(container.path),
            "path": .string(gamesRoot.path)
        ])
        #expect(addedAgain.object?["excludedFolders"]?.arrayValues?.isEmpty == true)
        #expect(try LibraryVisibility.load(bottleURL: container).hiddenIdentities.isEmpty)

        let automatic = try await service.call("folders.automaticMetadata", params: [
            "container": .string(container.path),
            "enabled": .bool(false)
        ])
        #expect(automatic.object?["automaticMetadata"] == .bool(false))

        let hiddenPinned = try await service.call("folders.visibility", params: [
            "container": .string(container.path),
            "included": .bool(false)
        ])
        #expect(hiddenPinned.object?["includePinnedAndSteam"] == .bool(false))
        #expect(try LibraryVisibility.load(bottleURL: container).includePinnedAndSteam == false)

        let secondRoot = container.appendingPathComponent("drive_c/More")
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        let addedMany = try await service.call("folders.addRoots", params: [
            "container": .string(container.path),
            "paths": .array([.string(gamesRoot.path), .string(secondRoot.path)])
        ])
        #expect(addedMany.object?["roots"]?.arrayValues == [
            .string(gamesRoot.path), .string(secondRoot.path)
        ])
    }

    @Test @MainActor func linuxApplicationServicesAndSchemaPlatformFilter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whisky-linux-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let container = root.appendingPathComponent("Bottle")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fakeWine = bin.appendingPathComponent("wine")
        try Data("#!/bin/sh\n".utf8).write(to: fakeWine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeWine.path)
        let file = container.appendingPathComponent("readme.txt")
        try Data("ok".utf8).write(to: file)

        let opened = LockBox<URL?>()
        let linux = LinuxApplicationServices(searchPaths: [bin]) { url in
            opened.set(url)
        }
        let service = ApplicationService(workspace: ApplicationWorkspace(containers: [container]), native: linux)
        let resources = try await service.call("system.resources", params: [:])
        #expect(resources.object?["tools"]?.object?["wine"] == .string(fakeWine.path))

        _ = try await service.call("system.reveal", params: [
            "container": .string(container.path),
            "path": .string(file.path)
        ])
        #expect(opened.get()?.path == container.path)

        let schema = try await service.call("configuration.schema", params: ["platform": .string("linux")])
        let ids = Set((schema.arrayValues ?? []).compactMap { $0.object?["id"]?.string })
        #expect(!ids.contains("metalFX"))
        #expect(ids.contains("dxvkAsync"))
    }

    @Test func procStatStartTimeAndProcessIdentityProvider() {
        let stat = "4242 (game (final) v2.exe) S 1 4242 4242 0 -1 4194304 100 0 0 0 10 5 0 0 20 0 4 0 987654321 1234"
        #expect(LinuxProcStatParser.startTime(from: stat) == 987_654_321)
        let provider = HostProcessIdentityProvider()
        let current = provider.currentProcess
        #expect(current.pid > 0)
        #expect(provider.isAlive(current))
        #expect(!provider.isAlive(HostProcessIdentity(pid: -1, birth: 1)))
    }

    @Test func linuxWineHostInspectsELFAndBinfmtAndLocale() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whisky-elf-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("wine")
        let bin = runtime.appendingPathComponent("bin")
        let binfmtDir = root.appendingPathComponent("binfmt")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binfmtDir, withIntermediateDirectories: true)

        var x64Header = Data(repeating: 0, count: 20)
        x64Header[0] = 0x7F
        x64Header[1] = 0x45
        x64Header[2] = 0x4C
        x64Header[3] = 0x46
        x64Header[4] = 2 // 64-bit
        x64Header[5] = 1 // little-endian
        x64Header[6] = 1
        x64Header[16] = 0x02 // ET_EXEC
        x64Header[18] = 0x3E // EM_X86_64
        let wineBin = bin.appendingPathComponent("wine")
        let serverBin = bin.appendingPathComponent("wineserver")
        try x64Header.write(to: wineBin)
        try x64Header.write(to: serverBin)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wineBin.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverBin.path)

        let fakeBox64 = root.appendingPathComponent("box64")
        try Data("#!/bin/sh\n".utf8).write(to: fakeBox64)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBox64.path)

        let host = try #require(LinuxWineHost(
            runtimeURL: runtime,
            environment: ["WHISKY_WINE_EMULATOR": fakeBox64.path]
        ))
        #expect(host.architecture == "x86_64")
        #expect(host.translation == .emulator(fakeBox64))
        #expect(host.canExecute)

        var armHeader = x64Header
        armHeader[18] = 0xB7 // EM_AARCH64
        let rosettaEntry = """
        enabled
        interpreter /run/rosetta/rosetta
        flags: POCF
        offset 0
        magic 7f454c4602010100000000000000000002003e00
        mask fffffffffffefe00fffffffffffffffffeffffff
        """
        try Data(rosettaEntry.utf8).write(to: binfmtDir.appendingPathComponent("rosetta"))
        #expect(LinuxWineHost.binfmtHandler(for: [UInt8](x64Header), directory: binfmtDir) == "rosetta")
        #expect(LinuxWineHost.binfmtHandler(for: [UInt8](armHeader), directory: binfmtDir) == nil)

        var env = ["LANG": "not_A_Real_Locale.GB2312"]
        LinuxWineHost.applyUsableLocale(to: &env)
        #expect(env["LC_ALL"]?.uppercased().contains("UTF") == true || env["LC_ALL"] == "C.UTF-8")
    }

    @Test func linuxLaunchConfigurationComposesSettingsOverridesAndProgramOptions() {
        let composed = LinuxLaunchConfiguration.compose(
            values: [
                "enhancedSync": .text("esync"),
                "graphicsBackend": .text("dxvk"),
                "dxvkAsync": .boolean(true),
                "dxvkHud": .text("fps"),
                "controllerCompatibilityMode": .boolean(true),
                "disableHIDAPI": .boolean(true)
            ],
            bottleEnvironment: ["BOTTLE_VAR": "from-bottle"],
            bottleDLLOverrides: [("dinput8", "n,b")],
            program: [
                "arguments": "--windowed \"--title=Hello World\"",
                "environment": ["PROGRAM_VAR": "from-program", "LANG": "C.UTF-8"],
                "overrides": [
                    "dllOverrides": [
                        ["dllName": "winmm", "mode": "n,b"]
                    ]
                ]
            ]
        )
        #expect(composed.environment["WINEESYNC"] == "1")
        #expect(composed.environment["DXVK_ASYNC"] == "1")
        #expect(composed.environment["DXVK_HUD"] == "fps")
        #expect(composed.environment["SDL_JOYSTICK_HIDAPI"] == "0")
        #expect(composed.environment["SDL_GAMECONTROLLER_USE_BUTTON_LABELS"] == "0")
        #expect(composed.environment["WINEDLLOVERRIDES"]?.contains("d3d11=n,b") == true)
        #expect(composed.environment["WINEDLLOVERRIDES"]?.contains("dinput8=n,b") == true)
        #expect(composed.environment["WINEDLLOVERRIDES"]?.contains("winmm=n,b") == true)
        #expect(composed.environment["BOTTLE_VAR"] == "from-bottle")
        #expect(composed.environment["PROGRAM_VAR"] == "from-program")
        #expect(composed.environment["LC_ALL"] == "C.UTF-8")
        #expect(composed.arguments == ["--windowed", "--title=Hello World"])
    }

    @Test @MainActor func linuxTasklistParserAndWinetricksServiceWork() async throws {
        let csv = """
        "services.exe","48","Console","0","12,345 K"
        " explorer.exe ","76","Console","0","24,000 K"
        "tasklist.exe","104","Console","0","8,000 K"
        "game, edition.exe","220","Console","0","120,000 K"
        """
        let parsed = LinuxWineProcessHost.parseTasklist(csv)
        #expect(parsed == [
            .init(pid: 48, name: "services.exe", memory: "12,345 K", kind: "service", source: "untracked"),
            .init(pid: 76, name: "explorer.exe", memory: "24,000 K", kind: "system", source: "untracked"),
            .init(pid: 220, name: "game, edition.exe", memory: "120,000 K", kind: "app", source: "untracked")
        ])

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("whisky-wt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("vcrun2022\ncjkfonts\n# comment\nvcrun2022\n".utf8)
            .write(to: root.appendingPathComponent("winetricks.log"))

        let workspace = ApplicationWorkspace(containers: [root])
        let service = LinuxWinetricksService()
        let catalog = try await service.call("winetricks.catalog", params: [:], workspace: workspace)
        #expect(catalog.object?["categories"]?.arrayValues?.isEmpty == false)
        let installed = try await service.call(
            "winetricks.installed",
            params: ["container": .string(root.path)],
            workspace: workspace
        )
        let verbs = installed.object?["verbs"]?.arrayValues?.compactMap(\.string) ?? []
        #expect(verbs.contains("cjkfonts"))
        #expect(verbs.contains("vcrun2022"))
    }
}

private final class LockBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value = nil) where Value: ExpressibleByNilLiteral {
        self.value = value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private extension JSONValue {
    var arrayValues: [Self]? {
        if case let .array(values) = self {
            values
        } else {
            nil
        }
    }
}
