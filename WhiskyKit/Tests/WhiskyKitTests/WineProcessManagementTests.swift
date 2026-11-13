//
//  WineProcessManagementTests.swift
//  WhiskyKitTests
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

@testable import WhiskyKit
import XCTest

/// The injectable runner signature `Wine.$probeWineserverRunner` stores —
/// named so hoisted constants keep each `withValue` call to one literal
/// plus one trailing closure (the form both linters accept).
private typealias InjectedProbeRunner = @Sendable (
    URL, [String], [String: String], TimeInterval
) async throws -> WineProcessQuery.Result

final class WineProcessManagementTests: XCTestCase {
    /// The flag's value before this test — restored in tearDown.
    private var previousManagedInstallOverride: Bool?

    override func setUp() {
        super.setUp()
        // The managed engine must resolve without the real runtime install.
        previousManagedInstallOverride = WineEngine.managedInstallOverride
        WineEngine.managedInstallOverride = true
    }

    override func tearDown() {
        WineEngine.managedInstallOverride = previousManagedInstallOverride
        super.tearDown()
    }

    /// A fresh prefix can never have a live wineserver, so the probe must
    /// report false — whether wineserver spawns and exits nonzero (runtime
    /// installed) or the spawn itself fails (no runtime, e.g. CI).
    @MainActor
    func testWineserverProbeReturnsFalseForBottleWithoutServer() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bottle = Bottle(bottleUrl: tempDir, inFlight: false, isAvailable: true)

        let running = await Wine.isWineserverRunning(for: bottle)

        XCTAssertFalse(running)
    }

    /// The Processes page lists processes every few seconds, and a log file per
    /// listing buried the launch logs people are asked to attach. No runtime is
    /// installed for the test host, so tasklist.exe never starts, but a helper
    /// run creates its log before it starts the process.
    @MainActor
    func testListingProcessesLeavesNoLogFile() async throws {
        let (bottle, logsFolder) = try makeBottleWithoutRuntime()

        await Wine.$logsFolderOverride.withValue(logsFolder) {
            _ = try? await Wine.listProcesses(for: bottle)
        }

        XCTAssertEqual(logFiles(in: logsFolder), [])
    }

    /// The Steam client driver polls the process list while it watches Steam.
    @MainActor
    func testSteamDriverProcessListLeavesNoLogFile() async throws {
        let (bottle, logsFolder) = try makeBottleWithoutRuntime()

        await Wine.$logsFolderOverride.withValue(logsFolder) {
            _ = await WineSteamClientDriver(bottle: bottle).processList()
        }

        XCTAssertEqual(logFiles(in: logsFolder), [])
    }

    /// Keeps the two tests above honest: any other helper run still gets a log
    /// file, and it lands in the logs folder the test binds.
    @MainActor
    func testOtherHelperRunsStillWriteALogFile() async throws {
        let (bottle, logsFolder) = try makeBottleWithoutRuntime()

        await Wine.$logsFolderOverride.withValue(logsFolder) {
            _ = try? await Wine.runWine(["tasklist.exe", "/FO", "CSV"], bottle: bottle)
        }

        XCTAssertEqual(logFiles(in: logsFolder).count, 1)
    }

    // MARK: - V-01: killBottleAndWait Shutdown Race Tests

    private final class WineserverCallRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var args: [[String]] = []
        private var envs: [[String: String]] = []

        func record(args: [String], env: [String: String]) {
            lock.lock()
            defer { lock.unlock() }
            self.args.append(args)
            self.envs.append(env)
        }

        var recordedArgs: [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return args
        }

        var recordedEnvs: [[String: String]] {
            lock.lock()
            defer { lock.unlock() }
            return envs
        }
    }

    /// Verifies that killBottleAndWait invokes wineserver with -k to signal termination,
    /// followed by wineserver with -w to wait until processes exit, and injects the bottle's WINEPREFIX.
    @MainActor
    func testKillBottleAndWaitExecutesKillThenWait() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-shutdown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bottle = Bottle(bottleUrl: tempDir, inFlight: false, isAvailable: true)

        let recorder = WineserverCallRecorder()

        let killBottle = { Wine.killBottleAndWait(bottle: bottle, timeout: 5) }
        Wine.$wineserverSyncRunner.withValue({ args, env, _ in
            recorder.record(args: args, env: env)
        }, operation: killBottle)

        let executedArgs = recorder.recordedArgs
        let executedEnvs = recorder.recordedEnvs

        // Must execute ["-k"] first, then ["-w"]
        XCTAssertEqual(executedArgs.count, 2, "Expected exactly two wineserver invocations")
        XCTAssertEqual(executedArgs.first, ["-k"], "First wineserver invocation must be -k (kill signal)")
        XCTAssertEqual(executedArgs.last, ["-w"], "Second wineserver invocation must be -w (wait for exit)")

        // Must inject the correct WINEPREFIX environment
        for env in executedEnvs {
            XCTAssertEqual(env["WINEPREFIX"], tempDir.path(percentEncoded: false))
        }
    }

    /// Verifies that Wine.taskmgr creates a process run with ["taskmgr"] arguments.
    @MainActor
    func testWineTaskmgrInvocation() async throws {
        let (bottle, logsFolder) = try makeBottleWithoutRuntime()

        await Wine.$logsFolderOverride.withValue(logsFolder) {
            _ = try? await Wine.taskmgr(bottle: bottle)
        }

        // Verifies helper run created a log entry for taskmgr launch
        XCTAssertEqual(logFiles(in: logsFolder).count, 1)
    }

    // MARK: - Wineserver probe semantics

    private struct ProbeCall {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
    }

    private final class ProbeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [ProbeCall] = []

        func record(_ call: ProbeCall) {
            lock.lock()
            defer { lock.unlock() }
            calls.append(call)
        }

        var recorded: [ProbeCall] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }

        func reset() {
            lock.lock()
            defer { lock.unlock() }
            calls = []
        }
    }

    /// The probe contract: exit 0 means a server answered, 1 means none did,
    /// and anything else — a dyld crash, a signal — is UNKNOWN and throws, so
    /// a selection decision fails closed instead of mistaking it for idle.
    @MainActor
    func testProbeWineserverExitStatuses() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let bottle = Bottle(bottleUrl: tempDir, inFlight: false, isAvailable: true)
        let engine = fakeEngine(root: tempDir.appendingPathComponent("engine"))

        let recorder = ProbeRecorder()
        for code: Int32 in [0, 1] {
            recorder.reset()
            let probe: InjectedProbeRunner = { exe, args, env, _ in
                recorder.record(ProbeCall(executable: exe, arguments: args, environment: env))
                return WineProcessQuery.Result(output: "", diagnostics: "", exitCode: code)
            }
            let running = try await Wine.$probeWineserverRunner.withValue(probe) {
                try await Wine.probeWineserver(for: bottle, engine: engine)
            }
            XCTAssertEqual(running, code == 0)
            // The probe binds the SELECTED engine's server binary, not a
            // global one, and carries the bottle prefix in the environment.
            let calls = recorder.recorded
            XCTAssertEqual(calls.map(\.executable), [engine.wineserverBinary])
            XCTAssertEqual(calls.map(\.arguments), [["-k0"]])
            XCTAssertEqual(calls.first?.environment["WINEPREFIX"], tempDir.path(percentEncoded: false))
        }

        // Exit 2 (dyld crash, bad loader) throws instead of reading as idle.
        do {
            let crashed: InjectedProbeRunner = { _, _, _, _ in
                WineProcessQuery.Result(output: "", diagnostics: "dyld: boom", exitCode: 2)
            }
            _ = try await Wine.$probeWineserverRunner.withValue(crashed) {
                try await Wine.probeWineserver(for: bottle, engine: engine)
            }
            XCTFail("a non-0/1 probe status must throw")
        } catch let WineProcessQuery.Failure.commandFailed(code, message) {
            XCTAssertEqual(code, 2)
            XCTAssertTrue(message.contains("dyld: boom"))
        }
    }

    /// A wedged probe (timeout) also propagates as unknown, and two engines
    /// probe their own server binaries — not a shared default.
    @MainActor
    func testProbeWineserverBindsEachEngineAndPropagatesFailure() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let bottle = Bottle(bottleUrl: tempDir, inFlight: false, isAvailable: true)
        let engineA = fakeEngine(root: tempDir.appendingPathComponent("engineA"))
        let engineB = fakeEngine(root: tempDir.appendingPathComponent("engineB"))

        let recorder = ProbeRecorder()
        for engine in [engineA, engineB] {
            let probe: InjectedProbeRunner = { exe, _, _, _ in
                recorder.record(ProbeCall(executable: exe, arguments: [], environment: [:]))
                return WineProcessQuery.Result(output: "", diagnostics: "", exitCode: 1)
            }
            _ = try await Wine.$probeWineserverRunner.withValue(probe) {
                try await Wine.probeWineserver(for: bottle, engine: engine)
            }
        }
        XCTAssertEqual(
            recorder.recorded.map(\.executable), [engineA.wineserverBinary, engineB.wineserverBinary]
        )

        do {
            let wedged: InjectedProbeRunner = { _, _, _, _ in
                throw WineProcessQuery.Failure.timedOut
            }
            _ = try await Wine.$probeWineserverRunner.withValue(wedged) {
                try await Wine.probeWineserver(for: bottle, engine: engineA)
            }
            XCTFail("a timed-out probe must throw, not read as idle")
        } catch WineProcessQuery.Failure.timedOut {}
    }

    /// The informational sidebar probe still swallows failures into `false`;
    /// only the selection path treats unknown as blocking.
    @MainActor
    func testInformationalProbeSwallowsUnknownStatus() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let bottle = Bottle(bottleUrl: tempDir, inFlight: false, isAvailable: true)

        let crashed: InjectedProbeRunner = { _, _, _, _ in
            WineProcessQuery.Result(output: "", diagnostics: "", exitCode: 2)
        }
        let running = await Wine.$probeWineserverRunner.withValue(crashed) {
            await Wine.isWineserverRunning(for: bottle)
        }
        XCTAssertFalse(running)
    }

    /// A minimal external descriptor; no real binaries needed since the
    /// injected runner never spawns.
    private func fakeEngine(root: URL) -> WineEngine {
        WineEngine(
            id: root.lastPathComponent,
            name: root.lastPathComponent,
            rootURL: root,
            wineBinary: root.appendingPathComponent("bin/wine64"),
            wineserverBinary: root.appendingPathComponent("bin/wineserver"),
            libraryURL: root.appendingPathComponent("lib"),
            librariesURL: nil,
            isManaged: false,
            fingerprint: "fp",
            architectures: ["arm64"],
            availabilityError: nil,
            version: nil
        )
    }

    // MARK: - Helpers

    /// A bottle in a temporary folder, and a logs folder next to it for the test
    /// to bind as `Wine.logsFolderOverride`. Nothing is written under
    /// `~/Library/Logs`, and tests running in parallel processes never share a
    /// logs folder. Skips the test where a Wine runtime is installed for the test
    /// host, since tasklist.exe would really run there.
    @MainActor
    private func makeBottleWithoutRuntime() throws -> (bottle: Bottle, logsFolder: URL) {
        try XCTSkipIf(
            FileManager.default.isExecutableFile(atPath: Wine.wineBinary.path(percentEncoded: false)),
            "A Wine runtime is installed for the test host"
        )
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let bottleURL = dir.appending(path: "bottle", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bottleURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }
        let bottle = Bottle(bottleUrl: bottleURL, inFlight: false, isAvailable: true)
        return (bottle, dir.appending(path: "logs", directoryHint: .isDirectory))
    }

    /// The log files in `folder`, which the test owns.
    private func logFiles(in folder: URL) -> [URL] {
        let contents = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        return (contents ?? []).filter { $0.pathExtension == "log" }
    }
}
