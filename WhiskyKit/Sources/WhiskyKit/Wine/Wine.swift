// swiftlint:disable file_length
//
//  Wine.swift
//  Whisky
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
import os.log
import WhiskyCore

private let logger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "Wine")

// swiftlint:disable type_body_length

/// The core interface for interacting with Wine on macOS.
///
/// The `Wine` class provides static methods for executing Wine processes, running Windows programs,
/// and managing Wine-related operations within a ``Bottle``. It handles environment configuration,
/// process management, and output streaming.
///
/// ## Overview
///
/// Wine is a compatibility layer that allows Windows applications to run on macOS. This class
/// abstracts the complexity of Wine process management and provides a Swift-friendly API.
///
/// ## Running Programs
///
/// To run a Windows executable:
///
/// ```swift
/// @MainActor
/// func launchGame(at url: URL, in bottle: Bottle) async throws {
///     try await Wine.runProgram(at: url, bottle: bottle)
/// }
/// ```
///
/// ## Wine Commands
///
/// Execute arbitrary Wine commands:
///
/// ```swift
/// @MainActor
/// func getWineVersion() async throws -> String {
///     return try await Wine.wineVersion()
/// }
/// ```
///
/// ## Thread Safety
///
/// Most public methods require `@MainActor` context because they interact with ``Bottle``
/// which is main-actor isolated.
///
/// ## Topics
///
/// ### Running Programs
/// - ``runProgram(at:args:bottle:environment:)``
/// - ``runWine(_:bottle:environment:)``
/// - ``runBatchFile(url:bottle:)``
///
/// ### Wine Processes
/// - ``runWineProcess(name:args:bottle:environment:)``
/// - ``runWineserverProcess(name:args:bottle:environment:)``
///
/// ### Utilities
/// - ``wineVersion()``
/// - ``killBottle(bottle:)``
/// - ``enableDXVK(bottle:)``
/// - ``generateRunCommand(at:bottle:args:environment:)``
/// - ``generateTerminalEnvironmentCommand(bottle:)``
public class Wine {
    /// URL to the installed DXVK folder containing Direct3D-to-Vulkan translation libraries.
    private static let dxvkFolder: URL = WhiskyWineInstaller.libraryFolder.appending(path: "DXVK")
    /// URL to the installed DXMT payload containing Direct3D-11-to-Metal translation libraries.
    /// Absent on runtimes older than Wine Libraries 3.1.0.
    private static let dxmtFolder: URL = WhiskyWineInstaller.libraryFolder.appending(path: "DXMT")
    /// The URL to the `wine64` binary executable.
    ///
    /// This is the main Wine binary used to execute Windows applications.
    /// The binary is located within the WhiskyWine installation directory.
    public static let wineBinary: URL = WhiskyWineInstaller.binFolder.appending(path: "wine64")
    /// URL to the `wineserver` binary for Wine server management.
    private static let wineserverBinary: URL = WhiskyWineInstaller.binFolder.appending(path: "wineserver")

    /// The registry consulted to resolve ``BottleSettings/wineEngineID``.
    /// Tests bind a store of their own so engine ids resolve to fixtures
    /// rather than the user's real registry.
    @TaskLocal static var engineStoreOverride: WineEngineStore?

    /// The engine store every bottle-bound operation resolves through.
    static var engineStore: WineEngineStore {
        engineStoreOverride ?? .shared
    }

    /// The engine snapshot one Wine operation is pinned to: descriptor,
    /// approval map and the canonical prefix it was taken for, captured when
    /// ``withEngineOperation(bottle:_:)`` took the prefix's shared lease.
    /// Nested operations on the same prefix reuse it — an engine replaced or
    /// a bottle rebound mid-operation cannot swap binaries underneath it.
    /// `lease` retains the shared-lease handle so a TaskLocal child that
    /// outlives its parent keeps the lease alive and can never ride a
    /// recycled file descriptor.
    struct WineOperationContext: Sendable {
        let canonicalPrefix: String
        let engine: WineEngine
        let featureOverrides: [String: String]
        let lease: WineEngineLease.LeaseHandle?
    }

    /// The pinned engine of the in-flight ``withEngineOperation(bottle:_:)``.
    @TaskLocal static var operationContext: WineOperationContext?

    /// Canonical prefix path used to match a bottle against the pinned
    /// ``operationContext`` and key per-prefix engine leases.
    static func canonicalPrefixPath(_ prefixURL: URL) -> String {
        prefixURL.resolvingSymlinksInPath().standardizedFileURL
            .path(percentEncoded: false)
    }

    /// Runs `body` holding the prefix's shared engine lease, with the engine
    /// and feature approvals pinned for the whole operation.
    ///
    /// The shared lease blocks engine reselection until the operation —
    /// preparation *and* process lifetime — is over; a reselection in
    /// progress, here or in another Maltoria process, makes this throw
    /// ``WineEngineError/operationBusy(_:)`` instead of racing. Nested calls
    /// for the same prefix reuse the pinned context (same descriptor and
    /// approval snapshot, no re-lock); a different prefix takes its own
    /// lease.
    @MainActor
    static func withEngineOperation<T>(
        bottle: Bottle, engine explicitEngine: WineEngine? = nil,
        _ body: () async throws -> T
    ) async throws -> T {
        let canonical = canonicalPrefixPath(bottle.url)
        if operationContext?.canonicalPrefix == canonical {
            return try await body()
        }
        // The shared lease is taken BEFORE the snapshot: an exclusive
        // reselection completing between resolution and acquisition could
        // otherwise leave this operation pinned to an engine the bottle no
        // longer binds.
        let lease = try WineEngineLease.acquireHandle(
            prefixURL: bottle.url, registryURL: engineStore.registryURL, exclusive: false
        )
        let context: WineOperationContext
        do {
            let engine = try explicitEngine ?? Self.engine(for: bottle)
            let overrides = await MainActor.run { bottle.settings.wineFeatureOverrides }
            context = WineOperationContext(
                canonicalPrefix: canonical, engine: engine,
                featureOverrides: overrides, lease: lease
            )
        } catch {
            lease.release()
            throw error
        }
        // No explicit release on the success path: the context retains the
        // handle and its deinit frees the fd when the LAST holder dies — a
        // TaskLocal child outliving this scope keeps the shared lease until
        // its own context goes away, never on a recycled descriptor.
        return try await $operationContext.withValue(context) {
            try await body()
        }
    }

    /// The synchronous twin of ``withEngineOperation(bottle:_:)`` for
    /// command-string builders that cannot suspend. Identical semantics:
    /// same-prefix nesting reuses the pinned context, otherwise the shared
    /// lease and descriptor+approval snapshot pin for the body's duration.
    @MainActor
    static func withEngineOperation<T>(
        bottle: Bottle, _ body: () throws -> T
    ) throws -> T {
        let canonical = canonicalPrefixPath(bottle.url)
        if operationContext?.canonicalPrefix == canonical {
            return try body()
        }
        // Same ordering as the async variant: lease first, snapshot second.
        let lease = try WineEngineLease.acquireHandle(
            prefixURL: bottle.url, registryURL: engineStore.registryURL, exclusive: false
        )
        let context: WineOperationContext
        do {
            let engine = try engine(for: bottle)
            context = WineOperationContext(
                canonicalPrefix: canonical,
                engine: engine,
                featureOverrides: bottle.settings.wineFeatureOverrides,
                lease: lease
            )
        } catch {
            lease.release()
            throw error
        }
        // Same RAII-only release as the async variant: ``context`` owns the
        // handle, freed when the last retaining context dies.
        return try $operationContext.withValue(context) {
            try body()
        }
    }

    /// A spawned process and the output stream it produces — the pair
    /// ``leasedProcessStream(bottle:make:)`` needs to bind the engine lease
    /// to real process termination, not just stream iteration.
    private struct SpawnedProcessStream {
        let stream: AsyncStream<ProcessOutput>
        let process: Process
    }

    /// Resolves the engine a bottle is bound to.
    ///
    /// Inside ``withEngineOperation(bottle:_:)`` the pinned engine comes back,
    /// so one operation never mixes two engines. Otherwise the registry is
    /// resolved fresh: an unregistered, missing, structurally invalid or
    /// host-unusable id throws ``WineEngineError`` — there is no managed
    /// fallback, and an engine this host cannot execute cannot launch.
    @MainActor
    static func engine(for bottle: Bottle) throws -> WineEngine {
        let canonical = canonicalPrefixPath(bottle.url)
        if operationContext?.canonicalPrefix == canonical,
           let pinned = operationContext?.engine {
            return pinned
        }
        let engine: WineEngine
        do {
            engine = try engineStore.resolve(id: bottle.settings.wineEngineID)
        } catch let error as WineEngineError {
            throw error
        } catch {
            throw WineEngineError.engineUnavailable(error.localizedDescription)
        }
        guard engine.isAvailable else {
            throw WineEngineError.engineUnavailable(
                engine.availabilityError
                    ?? "The selected Wine engine is not usable on this host"
            )
        }
        return engine
    }

    /// The feature approvals launches under `bottle` honour: the snapshot
    /// pinned by ``withEngineOperation(bottle:_:)`` while one is in flight,
    /// live settings otherwise — an approval granted or revoked mid-launch
    /// does not change the policy that launch was prepared under.
    @MainActor
    static func featureOverrides(for bottle: Bottle) -> [String: String] {
        let canonical = canonicalPrefixPath(bottle.url)
        if operationContext?.canonicalPrefix == canonical {
            return operationContext?.featureOverrides ?? [:]
        }
        return bottle.settings.wineFeatureOverrides
    }

    /// Feature gate for launches under `engine`: whether a feature may take
    /// effect, honouring the bottle's persisted confirmations.
    ///
    /// The managed engine keeps historical behavior — every feature routes
    /// through the same availability checks it always did, so nothing is
    /// newly gated there. External engines apply the
    /// supported/unverified/unavailable policy.
    static func featureGate(
        for engine: WineEngine, overrides: [String: String]
    ) -> (WineEngineFeature) -> Bool {
        engine.isManaged
            ? { _ in true }
            : { feature in engine.isFeatureEnabled(feature, overrides: overrides) }
    }

    /// What `.recommended` resolves to for a launch under `engine`.
    ///
    /// Managed keeps ``GraphicsBackendResolver``'s answer. An external engine
    /// recommends only backends its feature policy actually enables — base
    /// WineD3D unless a payload is present or the user confirmed an unverified
    /// capability — so nothing is promised a launch cannot deliver.
    static func recommendedBackend(
        for engine: WineEngine,
        overrides: [String: String],
        managedDefault: GraphicsBackend = GraphicsBackendResolver.resolve()
    ) -> GraphicsBackend {
        if engine.isManaged {
            return managedDefault
        }
        if engine.isFeatureEnabled(.d3dMetal, overrides: overrides) {
            return .d3dMetal
        }
        if engine.isFeatureEnabled(.dxmt, overrides: overrides) {
            return .dxmt
        }
        if engine.isFeatureEnabled(.dxvk, overrides: overrides) {
            return .dxvk
        }
        return .wined3d
    }

    /// The backend policy `bottle`'s selected engine imposes: what
    /// `.recommended` resolves to, whether the runtime's builtin `d3d12` is
    /// D3DMetal's, and the feature gate — the same triple
    /// `prepareProgramLaunch` resolves under, so ``EffectiveBackend``
    /// predictions cannot name a backend the launch would refuse.
    struct EngineBackendPolicy {
        let recommendedBackend: GraphicsBackend
        let d3dMetalDeployed: Bool
        let featureGate: (WineEngineFeature) -> Bool
    }

    /// An unresolvable engine predicts nothing usable: the recommendation is
    /// base WineD3D and no feature is enabled.
    @MainActor
    static func backendPolicy(for bottle: Bottle) -> EngineBackendPolicy {
        guard let engine = try? engine(for: bottle) else {
            return EngineBackendPolicy(
                recommendedBackend: .wined3d,
                d3dMetalDeployed: false,
                featureGate: { _ in false }
            )
        }
        let approvals = featureOverrides(for: bottle)
        return EngineBackendPolicy(
            recommendedBackend: recommendedBackend(for: engine, overrides: approvals),
            d3dMetalDeployed: engine.isManaged
                ? GPTKImporter.isDeployed()
                : engine.payloadRoot(.d3dMetal) != nil,
            featureGate: featureGate(for: engine, overrides: approvals)
        )
    }

    /// The backend `gate` actually permits: a translation backend whose
    /// feature the engine does not enable becomes base WineD3D, so a saved
    /// choice on an external engine can never inject DLL overrides or deploy
    /// managed payload files the engine cannot serve.
    static func gatedBackend(
        _ backend: GraphicsBackend, gate: (WineEngineFeature) -> Bool
    ) -> GraphicsBackend {
        switch backend {
        case .dxvk: gate(.dxvk) ? .dxvk : .wined3d
        case .dxmt: gate(.dxmt) ? .dxmt : .wined3d
        case .d3dMetal: gate(.d3dMetal) ? .d3dMetal : .wined3d
        case .wined3d, .recommended: .wined3d
        }
    }

    /// Run a process on a executable file given by the `executableURL`
    private static func runProcess(
        name: String? = nil, args: [String], environment: [String: String], executableURL: URL, directory: URL? = nil,
        fileHandle: FileHandle?
    ) throws -> SpawnedProcessStream {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = args
        process.currentDirectoryURL = directory ?? executableURL.deletingLastPathComponent()
        process.environment = ["wine64", "wine"].contains(executableURL.lastPathComponent)
            ? prefixSetupEnvironment(args: args, environment: environment)
            : environment
        process.qualityOfService = .userInitiated

        let stream = try process.runStream(
            name: name ?? args.joined(separator: " "), fileHandle: fileHandle
        )
        // Bind the in-flight operation's shared lease to the process's real
        // lifetime: the waiter retains ONE handle reference until observed
        // exit, then drops it — RAII frees the fd only once every context
        // and waiter ref is gone, so a TaskLocal child that outlives its
        // parent never unlocks while its own context still holds.
        if let lease = operationContext?.lease {
            Task.detached(priority: .utility) {
                process.waitUntilExit()
                withExtendedLifetime(lease) {}
            }
        }
        return SpawnedProcessStream(stream: stream, process: process)
    }

    /// Run a `wine` process with the given arguments and environment variables returning a stream of output
    private static func runWineProcess(
        name: String? = nil, args: [String], environment: [String: String] = [:],
        executableURL: URL = wineBinary,
        fileHandle: FileHandle?
    ) throws -> SpawnedProcessStream {
        try runProcess(
            name: name, args: args, environment: environment, executableURL: executableURL,
            fileHandle: fileHandle
        )
    }

    /// Run a `wineserver` process with the given arguments and environment variables returning a stream of output
    private static func runWineserverProcess(
        name: String? = nil, args: [String], environment: [String: String] = [:],
        executableURL: URL = wineserverBinary,
        fileHandle: FileHandle?
    ) throws -> SpawnedProcessStream {
        try runProcess(
            name: name, args: args, environment: environment, executableURL: executableURL,
            fileHandle: fileHandle
        )
    }

    /// Runs a Wine process with the given arguments and returns a stream of output.
    ///
    /// This method executes the Wine binary with the specified arguments within the context
    /// of a bottle. The bottle's settings are used to configure the Wine environment.
    ///
    /// - Parameters:
    ///   - name: An optional descriptive name for the process, used in logging.
    ///   - args: The command-line arguments to pass to Wine.
    ///   - bottle: The ``Bottle`` context in which to run the process.
    ///   - environment: Additional environment variables to set for this process.
    /// - Returns: An `AsyncStream` of ``ProcessOutput`` containing stdout, stderr, and lifecycle events.
    /// - Throws: An error if the process cannot be started.
    @MainActor
    public static func runWineProcess(
        name: String? = nil, args: [String], bottle: Bottle, environment: [String: String] = [:]
    ) throws -> AsyncStream<ProcessOutput> {
        try leasedProcessStream(bottle: bottle) {
            let engine = try engine(for: bottle)
            let fileHandle = try makeFileHandle()
            fileHandle.writeApplicationInfo()
            fileHandle.writeInfo(for: bottle)

            WineUserProfile.reconcile(bottleURL: bottle.url)
            let wineEnvironment = try constructWineEnvironment(
                for: bottle, environment: environment, engine: engine
            )

            return try runProcess(
                name: name, args: args, environment: wineEnvironment, executableURL: engine.wineBinary,
                fileHandle: fileHandle
            )
        }
    }

    /// Runs a Wine server process with the given arguments and returns a stream of output.
    ///
    /// The Wine server manages shared resources and state for all Wine processes in a bottle.
    /// This method is typically used for administrative operations like killing all processes.
    ///
    /// - Parameters:
    ///   - name: An optional descriptive name for the process, used in logging.
    ///   - args: The command-line arguments to pass to wineserver.
    ///   - bottle: The ``Bottle`` context in which to run the server process.
    ///   - environment: Additional environment variables to set for this process.
    /// - Returns: An `AsyncStream` of ``ProcessOutput`` containing stdout, stderr, and lifecycle events.
    /// - Throws: An error if the process cannot be started.
    @MainActor
    public static func runWineserverProcess(
        name: String? = nil, args: [String], bottle: Bottle, environment: [String: String] = [:]
    ) throws -> AsyncStream<ProcessOutput> {
        try leasedProcessStream(bottle: bottle) {
            let engine = try engine(for: bottle)
            let fileHandle = try makeFileHandle()
            fileHandle.writeApplicationInfo()
            fileHandle.writeInfo(for: bottle)

            let wineserverEnvironment = try constructWineEnvironment(
                for: bottle, environment: environment, engine: engine
            )

            return try runProcess(
                name: name, args: args, environment: wineserverEnvironment,
                executableURL: engine.wineserverBinary,
                fileHandle: fileHandle
            )
        }
    }

    /// Runs `make` inside the prefix's shared engine lease and binds the lease
    /// to the spawned process's lifetime: reselection is refused while the
    /// process the stream drives is alive. Inside an enclosing
    /// ``withEngineOperation(bottle:_:)`` the pinned context already covers
    /// the call and no new lease is taken.
    ///
    /// Release is tied to real process completion — `waitUntilExit` — not to
    /// the stream consumer: cancelling iteration terminates the child through
    /// ``Process/runStream(name:fileHandle:)``, and only its observed exit
    /// frees the exclusive path.
    @MainActor
    private static func leasedProcessStream(
        bottle: Bottle,
        make: @MainActor () throws -> SpawnedProcessStream
    ) throws -> AsyncStream<ProcessOutput> {
        let canonical = canonicalPrefixPath(bottle.url)
        if operationContext?.canonicalPrefix == canonical {
            return try make().stream
        }
        // Lease before snapshot, matching ``withEngineOperation(bottle:_:)``.
        let lease = try WineEngineLease.acquireHandle(
            prefixURL: bottle.url, registryURL: engineStore.registryURL, exclusive: false
        )
        let spawned: SpawnedProcessStream
        do {
            let engine = try engine(for: bottle)
            let context = WineOperationContext(
                canonicalPrefix: canonical,
                engine: engine,
                featureOverrides: bottle.settings.wineFeatureOverrides,
                lease: lease
            )
            spawned = try $operationContext.withValue(context) {
                try make()
            }
        } catch {
            lease.release()
            throw error
        }
        // No waiter here: ``runProcess`` already retained the lease inside
        // `make()` (the `withValue` above made this context current), so the
        // lease is held until the spawned process is observed dead — and the
        // fd frees only when that last reference dies, RAII-style.
        return spawned.stream
    }

    /// Result of a Wine program run, providing the exit code and log file URL
    /// for post-run diagnostics.
    public struct ProgramRunResult: Sendable {
        /// The exit code from the `wine start` process.
        public let exitCode: Int32
        /// URL to the log file created for this run.
        public let logFileURL: URL
        /// The UUID of the run log entry created for this run.
        ///
        /// Use this to correlate the run result with the run log history
        /// entry, e.g., to open the correct log entry in the console UI.
        public let runLogEntryId: UUID

        public init(exitCode: Int32, logFileURL: URL, runLogEntryId: UUID) {
            self.exitCode = exitCode
            self.logFileURL = logFileURL
            self.runLogEntryId = runLogEntryId
        }
    }

    /// What a program launch runs once its bottle has been prepared for it.
    ///
    /// Returned by `prepareProgramLaunch`, and turned into a shell command by
    /// ``generateRunCommand(for:wineBinary:)``.
    struct PreparedLaunch: Equatable, Sendable {
        /// The environment `wine64` runs with.
        ///
        /// Holds no `WINEDLLOVERRIDES` unless the overrides are meant for a
        /// process this launch spawns: preparation moved the launch's own
        /// overrides into the prefix registry, where no child inherits them.
        let environment: [String: String]
        /// The arguments `wine64` runs with: `start /unix` and the program, or
        /// `explorer /desktop=...` for a program that runs in a virtual desktop.
        let arguments: [String]
        /// The loader the launch runs — the selected engine's binary, so a
        /// printed command names the same executable the launch would.
        let wineBinary: URL

        init(environment: [String: String], arguments: [String], wineBinary: URL = Wine.wineBinary) {
            self.environment = environment
            self.arguments = arguments
            self.wineBinary = wineBinary
        }
    }

    /// Runs a Windows executable within a Wine bottle.
    ///
    /// This is the primary method for launching Windows applications. It prepares the bottle
    /// with `prepareProgramLaunch` and then executes the program using `wine start /unix`.
    ///
    /// - Note: If DXVK is enabled in the bottle's settings (`bottle.settings.dxvk`),
    ///   the DXVK libraries will be automatically installed into the bottle before
    ///   execution. This ensures Direct3D games use Vulkan translation for better
    ///   performance on macOS.
    ///
    /// ## Example
    ///
    /// ```swift
    /// @MainActor
    /// func launchGame() async throws {
    ///     let gameURL = bottle.url
    ///         .appendingPathComponent("drive_c")
    ///         .appendingPathComponent("Games")
    ///         .appendingPathComponent("MyGame.exe")
    ///
    ///     try await Wine.runProgram(at: gameURL, bottle: bottle)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - url: The URL to the Windows executable (.exe) file.
    ///   - args: Optional command-line arguments to pass to the program.
    ///   - bottle: The ``Bottle`` in which to run the program.
    ///   - environment: Additional environment variables for this execution.
    ///   - programOverrides: Optional per-program setting overrides. `nil` fields inherit from bottle.
    ///   - programSettings: The program's settings, which carry its diagnostic `WINEDEBUG` preset.
    ///   - gameProfileEnvironment: Environment variables from the game's GameDB profile.
    ///   - overridesApplyToDescendants: Whether the DLL overrides belong to a process this
    ///     one spawns rather than to `url` itself, as when `steam.exe` launches a game.
    ///   - descendantExecutables: The executable names of what this launch starts, when the
    ///     overrides apply to descendants.
    ///   - descendantLaunchers: Launchers what this launch starts brings up on its own.
    ///   - onOutput: Receives each output event of the `wine64` process as it arrives,
    ///     starting with ``ProcessOutput/started`` once the process is running.
    /// - Returns: The exit code and log file of the run.
    /// - Throws: An error if the program cannot be started or Wine encounters an error.
    @discardableResult
    @MainActor
    public static func runProgram(
        at url: URL, args: [String] = [], bottle: Bottle, environment: [String: String] = [:],
        programOverrides: ProgramOverrides? = nil, programSettings: ProgramSettings? = nil,
        gameProfileEnvironment: [String: String] = [:],
        overridesApplyToDescendants: Bool = false,
        descendantExecutables: [String] = [],
        descendantLaunchers: [LauncherType] = [],
        onOutput: (@MainActor (ProcessOutput) -> Void)? = nil
    ) async throws -> ProgramRunResult {
        try await runProgram(at: url, bottle: bottle, programSettings: programSettings, onOutput: onOutput) {
            try await prepareProgramLaunch(
                at: url, args: args, bottle: bottle, environment: environment,
                programOverrides: programOverrides, programSettings: programSettings,
                gameProfileEnvironment: gameProfileEnvironment,
                overridesApplyToDescendants: overridesApplyToDescendants,
                descendantExecutables: descendantExecutables,
                descendantLaunchers: descendantLaunchers
            )
        }
    }

    /// Disables App Nap while Wine launches when the bottle opted in.
    ///
    /// This token is held while the `wine start` launcher process runs. The actual
    /// game process continues as a child of wineserver after the launcher exits. Full
    /// App Nap prevention for the entire game session would require tracking wineserver,
    /// but this provides protection during the critical startup/initialization phase.
    @MainActor
    private static func beginActivityIfNeeded(for bottle: Bottle) -> NSObjectProtocol? {
        bottle.settings.disableAppNap
            ? ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Wine process running for \(bottle.settings.name)"
            )
            : nil
    }

    /// Runs a program once `prepare` has prepared the bottle for it.
    ///
    /// The public entry point prepares from its parameters. ``Program`` passes
    /// its own preparation instead, the one whose result `WhiskyCmd run --command`
    /// prints, so a program's launches and its printed command apply the same
    /// settings.
    ///
    /// - Parameters:
    ///   - url: The URL to the Windows executable (.exe) file.
    ///   - bottle: The ``Bottle`` in which to run the program.
    ///   - programSettings: The program's settings, whose `WINEDEBUG` preset the run log records.
    ///   - onOutput: Receives each output event of the `wine64` process as it arrives.
    ///   - prepare: Prepares the bottle for the launch and returns what the launch runs.
    /// - Returns: The exit code and log file of the run.
    /// - Throws: An error if the bottle cannot be prepared or the program cannot be started.
    @MainActor
    static func runProgram(
        at url: URL, bottle: Bottle, programSettings: ProgramSettings?,
        onOutput: (@MainActor (ProcessOutput) -> Void)?,
        prepare: @MainActor () async throws -> PreparedLaunch
    ) async throws -> ProgramRunResult {
        // Note: Launcher detection and fix application happen before this method
        // is called, via LauncherFixes.detectAndApply from the app's run paths
        // (FileOpenView/BottleView/ProgramMenuView).

        // Disable App Nap if requested to prevent macOS from throttling Wine processes.
        let activityToken = beginActivityIfNeeded(for: bottle)
        defer {
            if let token = activityToken {
                ProcessInfo.processInfo.endActivity(token)
            }
        }

        // The whole run — preparation and process lifetime — holds the
        // prefix's shared engine lease: reselection refuses to enter while a
        // launch is in flight, and the pinned context keeps loader, server
        // and approval snapshot consistent the whole way through.
        try Task.checkCancellation()
        return try await withEngineOperation(bottle: bottle) {
            let launch = try await prepare()
            try Task.checkCancellation()

            // Opened after preparation, not before: the registry imports during
            // preparation open logs of their own, and this way the program's log
            // stays the newest in the folder, the one people are asked to attach.
            let (fileHandle, logFileURL) = try makeFileHandleWithURL()
            fileHandle.writeApplicationInfo()
            fileHandle.writeInfo(for: bottle)

            // Create a run log entry to track this session
            let programName = url.lastPathComponent
            var runLogEntry = RunLogEntry(programName: programName, logFileName: logFileURL.lastPathComponent)

            // Record the active WINEDEBUG preset if one is set
            if launch.environment.keys.contains("WINEDEBUG") {
                runLogEntry.activeWineDebugPreset = programSettings?.activeWineDebugPreset?.rawValue
            }

            // Persist the "running" state immediately
            var runLogHistory = RunLogStore.load(for: programName, in: bottle.url)
            let prunedEntries = runLogHistory.append(runLogEntry)
            RunLogStore.save(runLogHistory, for: programName, in: bottle.url)

            // Clean up log files for pruned entries
            for pruned in prunedEntries {
                let prunedLogURL = Self.logsFolder.appending(path: pruned.logFileName)
                try? FileManager.default.removeItem(at: prunedLogURL)
            }

            // As late as possible: the bridge holds the prefix open only for a short
            // grace window before standing down, so it wants the smallest gap it can
            // get between itself and the program it is bridging for.
            DiscordIntegration.shared.programLaunching(url, bottle: bottle)

            var exitCode: Int32 = 0
            // The executable preparation resolved — never a fresh engine lookup:
            // the launch runs exactly what its environment was built for.
            for await output in try runProcess(
                name: programName,
                args: launch.arguments,
                environment: launch.environment, executableURL: launch.wineBinary,
                fileHandle: fileHandle
            ).stream {
                onOutput?(output)
                if case let .terminated(code) = output {
                    exitCode = code
                }
            }

            // Update the run log entry with exit information. The display-mode
            // failure flag feeds the legacy fullscreen suggestion on the next read.
            var updatedHistory = RunLogStore.load(for: programName, in: bottle.url)
            updatedHistory.markCompleted(
                id: runLogEntry.id,
                exitCode: exitCode,
                hasWineDebug: launch.environment.keys.contains("WINEDEBUG"),
                displayModeChangeFailed: DisplayModeFailure.detect(logFileURL: logFileURL)
            )
            RunLogStore.save(updatedHistory, for: programName, in: bottle.url)

            return ProgramRunResult(exitCode: exitCode, logFileURL: logFileURL, runLogEntryId: runLogEntry.id)
        }
    }

    /// Prepares a bottle to launch a program, without launching it.
    ///
    /// This is everything `runProgram` does before it starts the process: it
    /// adds the Noto CJK aliases once Source Han Sans is installed, resolves
    /// the effective graphics backend, deploys that backend's files into the
    /// prefix, builds the environment, and writes the launch's DLL overrides
    /// into the prefix registry. What it writes stays in the prefix, so running
    /// the returned arguments with the returned environment later, from a
    /// terminal, starts the program with the DLLs, fonts and settings a launch
    /// from Whisky gives it. What only happens while `runProgram` runs is not
    /// part of it: the log file and run log entry, the App Nap assertion, and
    /// the Discord bridge and presence.
    ///
    /// - Parameters:
    ///   - url: The URL to the Windows executable (.exe) file.
    ///   - args: Command-line arguments to pass to the program.
    ///   - bottle: The ``Bottle`` in which the program will run.
    ///   - environment: Additional environment variables for this execution.
    ///   - programOverrides: Optional per-program setting overrides. `nil` fields inherit from bottle.
    ///   - programSettings: The program's settings, which carry its diagnostic `WINEDEBUG` preset.
    ///   - gameProfileEnvironment: Environment variables from the game's GameDB profile.
    ///   - overridesApplyToDescendants: Whether the DLL overrides belong to a process this one
    ///     spawns. For a launcher they go to `descendantExecutables` and the environment keeps
    ///     none; otherwise they stay in the environment, since the registry can only scope
    ///     overrides to an executable whose name is known.
    ///   - descendantExecutables: The executable names of what this launch starts, when the
    ///     overrides apply to descendants. The overrides go into their `AppDefaults` entries,
    ///     replacing whatever an earlier launch or version left there.
    ///   - descendantLaunchers: Launchers what this launch starts brings up on its own, such as
    ///     the Rockstar Games Launcher a Rockstar title starts inside the Steam session.
    ///   - recommendedBackend: What `.recommended` resolves to for the bottle's games.
    ///     Defaults to the resolver's answer for the installed runtime; tests pin it.
    ///   - builtinD3D12IsD3DMetal: Whether the runtime's builtin `d3d12` is D3DMetal's.
    ///     Defaults to whether the GPTK payload is deployed; tests pin it.
    ///   - overrideWriter: What writes the DLL overrides into the prefix registry. Tests pass a
    ///     recorder, so they can see what a launch writes without running Wine.
    ///   - importer: What imports the CJK font aliases the prefix is missing. Tests pass a
    ///     recorder here too.
    /// - Returns: The environment and `wine64` arguments the launch runs with.
    /// - Throws: An error if a backend's files cannot be deployed or the DLL override import
    ///   cannot be started. A failed font alias import is only logged.
    @MainActor
    static func prepareProgramLaunch(
        at url: URL, args: [String] = [], bottle: Bottle, environment: [String: String] = [:],
        programOverrides: ProgramOverrides? = nil, programSettings: ProgramSettings? = nil,
        gameProfileEnvironment: [String: String] = [:],
        overridesApplyToDescendants: Bool = false,
        descendantExecutables: [String] = [],
        descendantLaunchers: [LauncherType] = [],
        recommendedBackend: GraphicsBackend? = nil,
        builtinD3D12IsD3DMetal: Bool = GPTKImporter.isDeployed(),
        engine explicitEngine: WineEngine? = nil,
        overrideWriter: DLLOverrideWriter = { try await syncDLLOverrides(bottle: $0, scopes: $1) },
        importer: RegistryImporter = { try await importRegistry(document: $0, bottle: $1) }
    ) async throws -> PreparedLaunch {
        // Preparation mutates the prefix (payload copies, registry imports)
        // and is called directly by generated-command paths too, not only by
        // `runProgram` — so it holds the shared engine lease itself. Under a
        // `runProgram` operation this reuses the already-pinned context.
        try await withEngineOperation(bottle: bottle, engine: explicitEngine) {
            try await prepareProgramLaunchImpl(
                at: url, args: args, bottle: bottle, environment: environment,
                programOverrides: programOverrides, programSettings: programSettings,
                gameProfileEnvironment: gameProfileEnvironment,
                overridesApplyToDescendants: overridesApplyToDescendants,
                descendantExecutables: descendantExecutables,
                descendantLaunchers: descendantLaunchers,
                recommendedBackend: recommendedBackend,
                builtinD3D12IsD3DMetal: builtinD3D12IsD3DMetal,
                engine: explicitEngine,
                overrideWriter: overrideWriter, importer: importer
            )
        }
    }

    /// The preparation body of ``prepareProgramLaunch(at:args:bottle:environment:`` —
    /// the full signature lives on that call — run under its engine operation.
    @MainActor
    private static func prepareProgramLaunchImpl(
        at url: URL, args: [String] = [], bottle: Bottle, environment: [String: String] = [:],
        programOverrides: ProgramOverrides? = nil, programSettings: ProgramSettings? = nil,
        gameProfileEnvironment: [String: String] = [:],
        overridesApplyToDescendants: Bool = false,
        descendantExecutables: [String] = [],
        descendantLaunchers: [LauncherType] = [],
        recommendedBackend: GraphicsBackend? = nil,
        builtinD3D12IsD3DMetal: Bool = GPTKImporter.isDeployed(),
        engine explicitEngine: WineEngine? = nil,
        overrideWriter: DLLOverrideWriter = { try await syncDLLOverrides(bottle: $0, scopes: $1) },
        importer: RegistryImporter = { try await importRegistry(document: $0, bottle: $1) }
    ) async throws -> PreparedLaunch {
        // Resolve the engine once for the whole preparation: backend
        // resolution, payload deployment and the environment all come from
        // the same snapshot. An invalid selection throws before the prefix
        // is mutated.
        let engine = try explicitEngine ?? Self.engine(for: bottle)
        let approvals = featureOverrides(for: bottle)
        let gate = featureGate(for: engine, overrides: approvals)
        let recommendedBackend = recommendedBackend ?? Self.recommendedBackend(
            for: engine, overrides: approvals
        )
        // Whether the builtin `d3d12` is D3DMetal's. Outside the managed
        // runtime that is true when the external tree carries its own
        // payload; Whisky never deploys the managed payload into it.
        let builtinD3D12IsD3DMetal = engine.isManaged
            ? builtinD3D12IsD3DMetal
            : engine.payloadRoot(.d3dMetal) != nil

        // Font aliases first, before any setting is read: their import can take
        // a few seconds, and a setting changed during it would leave this launch
        // with one backend's files and another's environment. It must finish
        // before the program starts, since a process reads the aliases once, and
        // like every Wine process it reconciles the user profile before starting.
        await syncCJKFontReplacements(bottle: bottle, importer: importer)

        // The effective backend for this launch: a program-level override wins
        // over the bottle setting, and `.recommended` resolves to its concrete
        // backend. This decides which translation layer's files are deployed;
        // the matching WINEDLLOVERRIDES come from the environment layers.
        // `.recommended` resolves against what is being launched, not just the
        // machine: a launcher is steered to DXVK. Not when the overrides are a
        // descendant's, as with `steam.exe -applaunch`: steam.exe is only the
        // vehicle there and the plan is the game's, so the game resolves the way
        // the bottle's games do. Steered, every game started that way got DXVK's
        // set, `d3d12=` included (#276). The launcher keeps DXVK through its own
        // `AppDefaults` entry, written from the launcher's set.
        let launchContext = LaunchPlanContext(
            url: url, bottle: bottle, programOverrides: programOverrides,
            overridesApplyToDescendants: overridesApplyToDescendants,
            recommendedBackend: recommendedBackend, builtinD3D12IsD3DMetal: builtinD3D12IsD3DMetal,
            gate: gate
        )
        let plan = resolveLaunchPlan(launchContext)
        let effectiveBackend = plan.effectiveBackend
        let programOverrides = plan.programOverrides

        // The profile has to resolve under whichever name this runtime uses
        // before anything in the bottle starts, or the app boots into an empty one.
        WineUserProfile.reconcile(bottleURL: bottle.url)

        try prepareBackendPrefix(effectiveBackend, bottle: bottle, engine: engine)
        try prepareTranslationPayloads(plan: plan, context: launchContext, engine: engine)

        // Build the Wine environment with program overrides flowing through the programUser layer
        var wineEnvironment = try constructWineEnvironment(
            for: bottle, environment: environment, targetURL: url, programOverrides: programOverrides,
            programSettings: programSettings, gameProfileEnvironment: gameProfileEnvironment,
            recommendedBackend: recommendedBackend, builtinD3D12IsD3DMetal: builtinD3D12IsD3DMetal,
            engine: engine
        )

        try await applyDLLOverrides(
            for: url, bottle: bottle,
            wineEnvironment: &wineEnvironment,
            applyToDescendants: overridesApplyToDescendants,
            descendantExecutables: descendantExecutables,
            descendantLaunchers: descendantLaunchers,
            recommendedBackend: recommendedBackend,
            builtinD3D12IsD3DMetal: builtinD3D12IsD3DMetal,
            engine: engine,
            writer: overrideWriter
        )

        return PreparedLaunch(
            environment: wineEnvironment,
            arguments: launchArguments(for: url, args: args, programOverrides: programOverrides),
            wineBinary: engine.wineBinary
        )
    }

    /// What one launch resolves to once steering and engine policy apply.
    private struct LaunchPlan {
        /// The launcher `url` belongs to, if any.
        let launcher: LauncherType?
        /// `launcher` when it may steer this launch: never for descendant
        /// overrides, and never when engine policy forbids DXVK.
        let steeredLauncher: LauncherType?
        /// The backend this launch deploys and reports.
        let effectiveBackend: GraphicsBackend
        /// `programOverrides` with the resolved backend pinned when the user
        /// left it `.recommended` and resolution landed elsewhere.
        let programOverrides: ProgramOverrides?
    }

    /// The inputs `resolveLaunchPlan` reads — one value so the resolver stays
    /// under the parameter limit while keeping every decision explicit.
    private struct LaunchPlanContext {
        let url: URL
        let bottle: Bottle
        let programOverrides: ProgramOverrides?
        let overridesApplyToDescendants: Bool
        let recommendedBackend: GraphicsBackend
        let builtinD3D12IsD3DMetal: Bool
        let gate: (WineEngineFeature) -> Bool
    }

    /// Resolves the effective backend for one launch under `gate`.
    ///
    /// A launcher is steered to DXVK only when the engine permits DXVK at
    /// all: an external engine without the capability runs launchers on its
    /// resolved recommendation instead. When the program's `.recommended`
    /// choice resolves elsewhere, the concrete backend is pinned into the
    /// returned overrides so the bottle composes the same decision — a
    /// steered launcher otherwise gets DXVK's files and none of its
    /// overrides.
    @MainActor private static func resolveLaunchPlan(_ context: LaunchPlanContext) -> LaunchPlan {
        let launcher = LauncherType.detect(from: context.url)
        let steeredLauncher = context.overridesApplyToDescendants || !context.gate(.dxvk)
            ? nil : launcher
        let effectiveBackendChoice = context.programOverrides?.graphicsBackend
            ?? context.bottle.settings.graphicsBackend
        // The shared resolution ``EffectiveBackend`` predicts for launch
        // replies: steering and the D3DMetal-without-payload fallback must
        // agree or the reported backend would name one the launch never uses.
        let effectiveBackend = gatedBackend(
            EffectiveBackend.resolve(
                effectiveBackendChoice, steeredLauncher: steeredLauncher,
                recommendedBackend: context.recommendedBackend,
                d3dMetalDeployed: context.builtinD3D12IsD3DMetal
            ),
            gate: context.gate
        )

        // The bottle composes its overrides from its own resolution, which does
        // not know what is being launched, so pin the decision here or a
        // steered launcher gets DXVK's files and none of its overrides.
        var pinnedOverrides = context.programOverrides
        if effectiveBackendChoice == .recommended, effectiveBackend != context.recommendedBackend {
            var pinned = pinnedOverrides ?? ProgramOverrides()
            pinned.graphicsBackend = effectiveBackend
            pinnedOverrides = pinned
        }
        return LaunchPlan(
            launcher: launcher,
            steeredLauncher: steeredLauncher,
            effectiveBackend: effectiveBackend,
            programOverrides: pinnedOverrides
        )
    }

    /// Deploys the translation-layer payloads `plan` calls for: the managed
    /// MetalFX placeholder and DXVK's DLL set. External engines never take
    /// part in the MetalFX placeholder — seeding it would write managed
    /// payload files into a prefix the external tree cannot serve anyway —
    /// and DXVK deploys only when the engine policy permits it, so a saved
    /// `dxvk` setting on an engine without the capability deploys nothing.
    @MainActor private static func prepareTranslationPayloads(
        plan: LaunchPlan, context: LaunchPlanContext, engine: WineEngine
    ) throws {
        // The MetalFX placeholder serves the bottle's games, and only D3DMetal
        // answers it. A launcher's own launch says nothing about them, so it is
        // keyed on what they resolve to: keyed on the launcher's DXVK, every
        // Steam start took away the placeholder its games need (#276).
        if engine.isManaged {
            let gamesBackend = gatedBackend(
                EffectiveBackend.resolve(
                    context.bottle.settings.graphicsBackend,
                    recommendedBackend: context.recommendedBackend,
                    d3dMetalDeployed: context.builtinD3D12IsD3DMetal
                ),
                gate: context.gate
            )
            applyMetalFX(
                bottle: context.bottle,
                backend: plan.steeredLauncher == nil ? plan.effectiveBackend : gamesBackend
            )
        }

        // Enable DXVK if needed: effective backend, the legacy program-level
        // flag (honored only without a backend override, mirroring
        // applyProgramOverrides), or launcher auto-enable.
        let legacyProgramDXVK = plan.programOverrides?.graphicsBackend == nil
            && plan.programOverrides?.dxvk == true
        let shouldEnableDXVK = context.gate(.dxvk)
            && (plan.effectiveBackend == .dxvk || legacyProgramDXVK ||
                (context.overridesApplyToDescendants && plan.launcher != nil) ||
                (context.bottle.settings.autoEnableDXVK &&
                    context.bottle.settings.detectedLauncher?.requiresDXVK == true))

        if shouldEnableDXVK {
            try enableDXVK(bottle: context.bottle, engine: engine)
        }
    }

    /// The `wine64` arguments for a launch, with an optional per-program virtual desktop.
    private static func launchArguments(
        for url: URL, args: [String], programOverrides: ProgramOverrides?
    ) -> [String] {
        guard let overrides = programOverrides,
              let vdEnabled = overrides.virtualDesktopEnabled, vdEnabled
        else {
            return ["start", "/unix", url.path(percentEncoded: false)] + args
        }
        let resolution = Self.resolveVirtualDesktopResolution(from: overrides)
        let desktopName = url.lastPathComponent.replacingOccurrences(of: " ", with: "_")
        return [
            "explorer", "/desktop=\(desktopName),\(resolution)",
            url.path(percentEncoded: false)
        ] + args
    }

    /// Resolves the virtual desktop resolution string from per-program overrides.
    ///
    /// - Parameter overrides: The program overrides containing display settings.
    /// - Returns: A resolution string like `"1920x1080"`.
    private static func resolveVirtualDesktopResolution(from overrides: ProgramOverrides) -> String {
        let preset = overrides.resolutionPreset ?? .r1920x1080
        if let dims = preset.dimensions {
            return "\(dims.width)x\(dims.height)"
        }
        if preset == .custom {
            let width = overrides.customResolutionWidth ?? 1_920
            let height = overrides.customResolutionHeight ?? 1_080
            return "\(width)x\(height)"
        }
        // matchDisplay fallback
        return "1920x1080"
    }

    /// Generates a shell command string for running a Windows program.
    ///
    /// This method creates a complete shell command that can be copied to a terminal
    /// or used in scripts. It includes all necessary environment variables and properly
    /// escapes arguments to prevent shell injection.
    ///
    /// - Parameters:
    ///   - url: The URL to the Windows executable.
    ///   - bottle: The ``Bottle`` configuration to use.
    ///   - args: Additional arguments as a single string.
    ///   - environment: Custom environment variables.
    ///   - preEscaped: If true, args are already shell-escaped and won't be escaped again.
    ///     Use this when passing an array of arguments that were individually escaped.
    /// - Returns: A shell-safe command string ready for execution.
    @MainActor
    public static func generateRunCommand(
        at url: URL, bottle: Bottle, args: String, environment: [String: String], preEscaped: Bool = false
    ) throws -> String {
        try withEngineOperation(bottle: bottle) {
            // Escape args and environment values to prevent shell injection from user-editable settings
            let escapedArgs = preEscaped ? args : args.esc
            let engine = try engine(for: bottle)
            WineUserProfile.reconcile(bottleURL: bottle.url)
            let wineEnv = try constructWineEnvironment(
                for: bottle, environment: environment, targetURL: url, engine: engine
            )
            return shellCommand(
                "\(engine.wineBinary.esc) start /unix \(url.esc) \(escapedArgs)", environment: wineEnv
            )
        }
    }

    /// Generates the shell command for a launch that has already been prepared.
    ///
    /// Unlike ``generateRunCommand(at:bottle:args:environment:preEscaped:)``, which
    /// builds the environment from the bottle again, this prints the launch's
    /// environment and arguments exactly as they are, so the command runs the way
    /// the launch would have: without the `WINEDLLOVERRIDES` that preparation moved
    /// into the prefix registry. Leaving the variable out is not enough for that,
    /// since the command only adds to the environment of the shell it runs in, and
    /// that shell may export the bottle's overrides already (`WhiskyCmd shellenv`
    /// and Open in Terminal do). So unless the launch sets the variable itself,
    /// `wine64` runs through `env -u WINEDLLOVERRIDES`.
    ///
    /// - Parameters:
    ///   - launch: A launch from `prepareProgramLaunch`.
    ///   - wineBinary: The `wine64` the command runs. Defaults to the launch's
    ///     own selected-engine loader; tests substitute a stub.
    /// - Returns: A shell-safe command string ready for execution.
    static func generateRunCommand(for launch: PreparedLaunch, wineBinary: URL? = nil) -> String {
        let wineBinary = wineBinary ?? launch.wineBinary
        var words = [wineBinary.path(percentEncoded: false)] + launch.arguments
        if launch.environment["WINEDLLOVERRIDES"] == nil {
            words = ["env", "-u", "WINEDLLOVERRIDES"] + words
        }
        return shellCommand(words.map(\.esc).joined(separator: " "), environment: launch.environment)
    }

    /// Prefixes `command` with an assignment for each environment variable.
    private static func shellCommand(_ command: String, environment: [String: String]) -> String {
        var wineCmd = command
        for envVar in environment {
            if isValidEnvKey(envVar.key) {
                // Keys are validated to be safe shell identifiers; values are escaped
                // Note: No quotes needed - .esc handles all shell metacharacter escaping
                wineCmd = "\(envVar.key)=\(envVar.value.esc) " + wineCmd
            } else {
                logger.debug("Skipping invalid environment key '\(envVar.key)' in generateRunCommand")
            }
        }

        return wineCmd
    }

    /// Generates shell commands to configure a terminal session for Wine development.
    ///
    /// The generated commands set up the PATH, create convenient aliases for Wine tools,
    /// and export all necessary environment variables for the given bottle. This is the
    /// text `WhiskyCmd shellenv` prints and Open in Terminal evaluates.
    ///
    /// ## Usage
    ///
    /// Evaluate the output in zsh, bash or fish to enable Wine commands:
    ///
    /// ```bash
    /// eval "$(WhiskyCmd shellenv MyBottle)"
    /// # Afterwards you can use:
    /// wine myprogram.exe
    /// winecfg
    /// regedit
    /// ```
    ///
    /// - Parameter bottle: The ``Bottle`` to configure the environment for.
    /// - Returns: A multi-line string of shell export commands and aliases.
    @MainActor
    public static func generateTerminalEnvironmentCommand(bottle: Bottle) throws -> String {
        try withEngineOperation(bottle: bottle) {
            let engine = try engine(for: bottle)
            return try generateTerminalEnvironmentCommand(
                engine: engine,
                environment: constructWineEnvironment(for: bottle, engine: engine)
            )
        }
    }

    /// Renders the terminal environment for one engine and a resolved environment.
    ///
    /// Every value, and every engine path, is quoted through ``ShellQuoting``, so nothing
    /// in it expands and `eval` sets each variable to exactly the string given here,
    /// control characters included. `WINE`, `WINESERVER` and every alias point at the
    /// engine's absolute binaries, so a `wine`-only tree (no `wine64` name) works and
    /// the PATH cannot fall through to a different runtime's tools.
    /// Variables are emitted in key order so the output is stable from run to run.
    ///
    /// Split out of ``generateTerminalEnvironmentCommand(bottle:)`` so tests can point
    /// the descriptor at a path the installer never uses.
    static func generateTerminalEnvironmentCommand(engine: WineEngine, environment: [String: String]) -> String {
        let loader = ShellQuoting.quoted(engine.wineBinary.path(percentEncoded: false))
        // The whole alias expansion is one quoted word: interpolating the
        // already-quoted loader inside double quotes would still expand
        // `$`/backticks/`"` in the path, and stripping them would corrupt it.
        func alias(_ name: String, _ args: String = "") -> String {
            let expansion = args.isEmpty ? loader : "\(loader) \(args)"
            return "alias \(name)=\(ShellQuoting.quoted(expansion))"
        }
        var cmd = """
        export PATH=\(ShellQuoting.quoted(engine.binFolder.path(percentEncoded: false))):\"$PATH\"
        export WINE=\(loader)
        export WINESERVER=\(ShellQuoting.quoted(engine.wineserverBinary.path(percentEncoded: false)))
        \(alias("wine"))
        \(alias("winecfg", "winecfg"))
        \(alias("msiexec", "msiexec"))
        \(alias("regedit", "regedit"))
        \(alias("regsvr32", "regsvr32"))
        \(alias("wineboot", "wineboot"))
        \(alias("wineconsole", "wineconsole"))
        \(alias("winedbg", "winedbg"))
        \(alias("winefile", "winefile"))
        \(alias("winepath", "winepath"))
        """

        for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
            if isValidEnvKey(key) {
                // Keys are validated to be safe shell identifiers. Values are single-quoted,
                // not `.esc`-escaped: `.esc` targets bare words, and inside double quotes the
                // shell keeps most of its backslashes, so `d3d11=n,b;dxgi=n,b` came back as
                // `d3d11\=n,b\;dxgi\=n,b`.
                cmd += "\nexport \(ShellQuoting.assignment(key, value))"
            } else {
                logger.debug("Skipping invalid environment key '\(key)' in generateTerminalEnvironmentCommand")
            }
        }

        return cmd
    }

    /// Run a `wineserver` command with the given arguments and return the output result
    @MainActor
    static func runWineserver(_ args: [String], bottle: Bottle) async throws -> String {
        try await withEngineOperation(bottle: bottle) {
            if let asyncRunner = wineserverAsyncRunner {
                return try await asyncRunner(args, bottle)
            }

            var result: [ProcessOutput] = []

            for await output in try Self.runWineserverProcess(args: args, bottle: bottle, environment: [:]) {
                result.append(output)
            }

            return result.compactMap { output -> String? in
                switch output {
                case .started, .terminated:
                    nil
                case let .message(message), let .error(message):
                    message
                }
            }.joined()
        }
    }

    /// Runs a Wine command and returns the collected output as a string.
    ///
    /// This method executes Wine with the given arguments and waits for completion,
    /// collecting all output into a single string. Use this for commands where you
    /// need the complete result, such as queries or configuration commands.
    ///
    /// - Parameters:
    ///   - args: The command-line arguments to pass to Wine.
    ///   - bottle: Optional ``Bottle`` context. If `nil`, runs without a bottle prefix.
    ///   - environment: Additional environment variables.
    /// - Returns: The combined stdout and stderr output from the Wine process.
    /// - Throws: An error if the process cannot be started.
    ///
    /// - Note: This overload maintains backward compatibility with optional Bottle parameter.
    @discardableResult
    @MainActor
    public static func runWine(
        _ args: [String], bottle: Bottle?, environment: [String: String] = [:]
    ) async throws -> String {
        if let bottle {
            try await runWineWithBottle(args, bottle: bottle, environment: environment)
        } else {
            try await runWineWithoutBottle(args, environment: environment)
        }
    }

    /// Run a `wine` command with the given arguments and a bottle context
    ///
    /// - Parameter createsLogFile: `false` for polls whose output is parsed rather
    ///   than read, such as `tasklist.exe`: a log file per poll buries the launch
    ///   logs people are asked to attach.
    @discardableResult
    @MainActor
    static func runWineWithBottle(
        _ args: [String], bottle: Bottle, environment: [String: String] = [:], createsLogFile: Bool = true
    ) async throws -> String {
        try await withEngineOperation(bottle: bottle) {
            var result: [String] = []
            let engine = try engine(for: bottle)
            let fileHandle = try createsLogFile ? makeFileHandle() : nil
            fileHandle?.writeApplicationInfo()
            fileHandle?.writeInfo(for: bottle)
            WineUserProfile.reconcile(bottleURL: bottle.url)
            let wineEnvironment = try constructWineEnvironment(
                for: bottle, environment: environment, engine: engine
            )

            for await output in try runWineProcess(
                args: args, environment: wineEnvironment, executableURL: engine.wineBinary,
                fileHandle: fileHandle
            ).stream {
                switch output {
                case .started, .terminated:
                    break
                case let .message(message), let .error(message):
                    result.append(message)
                }
            }

            return result.joined()
        }
    }

    /// Run a `wine` command without a bottle context (e.g., for --version queries)
    @discardableResult
    @MainActor
    private static func runWineWithoutBottle(
        _ args: [String], environment: [String: String] = [:],
        executableURL: URL = wineBinary
    ) async throws -> String {
        var result: [String] = []
        let fileHandle = try makeFileHandle()
        fileHandle.writeApplicationInfo()

        for await output in try runWineProcess(
            args: args, environment: environment, executableURL: executableURL, fileHandle: fileHandle
        ).stream {
            switch output {
            case .started, .terminated:
                break
            case let .message(message), let .error(message):
                result.append(message)
            }
        }

        return result.joined()
    }

    /// Returns the version string of the installed Wine binary.
    ///
    /// This queries Wine for its version and parses the result into a clean version string.
    /// Handles various Wine version formats including CrossOver Wine (WineCX).
    ///
    /// ## Example
    ///
    /// ```swift
    /// @MainActor
    /// func displayVersion() async throws {
    ///     let version = try await Wine.wineVersion()
    ///     print("Wine version: \(version)")  // e.g., "9.0"
    /// }
    /// ```
    ///
    /// - Returns: The Wine version string (e.g., "9.0", "8.0.2").
    /// - Throws: An error if Wine cannot be executed.
    @MainActor
    public static func wineVersion() async throws -> String {
        try await wineVersion(for: .managed)
    }

    /// Returns the version string of a specific engine's loader.
    ///
    /// The probe is bounded and engine-scoped: the engine's own loader runs
    /// with its library paths, a nonzero exit or a timeout throws instead of
    /// surfacing another runtime's answer. Injectable for tests — the real
    /// path never runs in this suite.
    ///
    /// - Parameter engine: The engine whose `wine64`/`wine` binary answers
    ///   `--version`. Detection never calls this: the version is probed only
    ///   where the existing flow already ran Wine (prefix bootstrap).
    nonisolated(unsafe) static var wineVersionProbe: ((WineEngine) async throws -> String)?

    @MainActor
    static func wineVersion(for engine: WineEngine) async throws -> String {
        var output: String
        if let probe = wineVersionProbe {
            output = try await probe(engine)
        } else {
            let result = try await WineProcessQuery.run(
                executable: engine.wineBinary,
                arguments: ["--version"], environment: engine.probeEnvironment, timeout: 15
            )
            guard result.exitCode == 0 else {
                throw WineProcessQuery.Failure.commandFailed(
                    result.exitCode, String(result.diagnostics.prefix(2_048))
                )
            }
            output = result.output
        }
        output.replace("wine-", with: "")

        // Deal with WineCX version names
        if let index = output.firstIndex(where: { $0.isWhitespace }) {
            return String(output.prefix(upTo: index))
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Executes a Windows batch file (.bat or .cmd) within a bottle.
    ///
    /// This runs the batch file using `cmd /c` through Wine, allowing execution
    /// of Windows batch scripts for installation or configuration tasks.
    ///
    /// - Parameters:
    ///   - url: The URL to the batch file.
    ///   - bottle: The ``Bottle`` in which to run the script.
    /// - Returns: The output from the batch file execution.
    /// - Throws: An error if execution fails.
    @discardableResult
    @MainActor
    public static func runBatchFile(url: URL, bottle: Bottle) async throws -> String {
        // A script can start a launcher too, so it gets the aliases a program launch gets.
        await syncCJKFontReplacements(bottle: bottle)
        return try await runWine(["cmd", "/c", url.path(percentEncoded: false)], bottle: bottle)
    }

    /// Terminates all Wine processes running in a bottle.
    ///
    /// This sends a kill signal to the bottle's Wine server, which terminates all
    /// associated processes. The operation is fire-and-forget: errors are logged
    /// but not propagated to the caller.
    ///
    /// Use this to forcefully stop all programs in a bottle, for example when
    /// a game becomes unresponsive.
    ///
    /// - Parameter bottle: The ``Bottle`` whose processes should be terminated.
    /// - Note: This is intentionally non-blocking. Errors are logged but not propagated.
    @MainActor
    public static func killBottle(bottle: Bottle) {
        Task {
            do {
                _ = try await runWineserver(["-k"], bottle: bottle)
            } catch {
                Logger.wineKit.error("Failed to kill bottle '\(bottle.settings.name)': \(error.localizedDescription)")
            }
        }
    }

    /// Kills a bottle's wineserver and blocks until the server and child processes fully exit.
    ///
    /// For `applicationWillTerminate`: a `Task` queued there never runs
    /// because the process exits as soon as the delegate returns, so the
    /// asynchronous ``killBottle(bottle:)`` left every Wine process alive
    /// on quit whatever the kill-on-quit setting said. Running `wineserver -k`
    /// sends the kill signal, and `wineserver -w` waits for all processes to exit.
    @MainActor
    public static func killBottleAndWait(bottle: Bottle, timeout: TimeInterval = 5) {
        // Best-effort shared lease: a kill must never be refused — leaving
        // processes running is the worse outcome — but when the lease is free
        // it keeps a reselection from resolving underneath it.
        let lease = try? WineEngineLease.acquire(
            prefixURL: bottle.url, registryURL: engineStore.registryURL, exclusive: false
        )
        defer { lease.map(WineEngineLease.release) }
        guard let engine = try? engine(for: bottle),
              let env = try? constructWineEnvironment(for: bottle, environment: [:], engine: engine)
        else {
            Logger.wineKit.error(
                "Failed to kill bottle '\(bottle.settings.name)': its Wine engine is unavailable"
            )
            return
        }
        let wineserver = engine.wineserverBinary
        let dir = wineserver.deletingLastPathComponent()

        if let syncRunner = wineserverSyncRunner {
            do {
                try syncRunner(["-k"], env, timeout)
                try syncRunner(["-w"], env, timeout)
            } catch {
                Logger.wineKit.error("Failed to kill bottle '\(bottle.settings.name)': \(error.localizedDescription)")
            }
            return
        }

        let deadline = Date().addingTimeInterval(timeout)

        // 1. Send kill signal (-k) to wineserver
        runWineserverSync(WineserverCall(
            wineserver: wineserver,
            arguments: ["-k"], env: env, dir: dir, deadline: deadline, bottleName: bottle.settings.name
        ))

        // 2. Wait for wineserver and child processes to fully terminate (-w)
        guard Date() < deadline else { return }
        runWineserverSync(WineserverCall(
            wineserver: wineserver,
            arguments: ["-w"], env: env, dir: dir, deadline: deadline, bottleName: bottle.settings.name
        ))
    }

    /// One synchronous `wineserver` invocation and the process it builds.
    private struct WineserverCall {
        let wineserver: URL
        let arguments: [String]
        let env: [String: String]
        let dir: URL
        let deadline: Date
        let bottleName: String
    }

    /// Runs `wineserver` with `call.arguments` and waits until it exits or
    /// `call.deadline` passes.
    private static func runWineserverSync(_ call: WineserverCall) {
        let process = Process()
        process.executableURL = call.wineserver
        process.arguments = call.arguments
        process.currentDirectoryURL = call.dir
        process.environment = call.env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Logger.wineKit.error(
                "Failed to run wineserver \(call.arguments) for '\(call.bottleName)': \(error.localizedDescription)"
            )
            return
        }
        while process.isRunning, Date() < call.deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
        }
    }

    /// Installs DXVK libraries into a bottle's Windows system directories.
    ///
    /// DXVK translates DirectX 9/10/11 calls to Vulkan, often providing better
    /// performance than Wine's built-in DirectX implementation. This method copies
    /// the DXVK DLL files to the bottle's system32 and syswow64 directories.
    ///
    /// - Parameters:
    ///   - bottle: The ``Bottle`` to install DXVK into.
    ///   - engine: The engine whose DXVK payload to deploy. The managed engine
    ///     uses the managed `Libraries/DXVK` folder; an external engine must
    ///     carry its own payload — managed payload files are never borrowed
    ///     for an external launch.
    /// - Throws: ``DXVKError/payloadMissing`` when the engine has no DXVK
    ///   payload, or an error if the DLL files cannot be copied.
    ///
    /// - Note: This is automatically called by ``runProgram(at:args:bottle:environment:)``
    ///   when DXVK is enabled in the bottle settings.
    @MainActor
    public static func enableDXVK(bottle: Bottle, engine explicitEngine: WineEngine? = nil) throws {
        // Bottle callers get the bottle's bound engine, not an implicit
        // managed default; explicit fixtures keep their direct parameter.
        let engine = try explicitEngine ?? Self.engine(for: bottle)
        guard let payload = engine.isManaged ? Wine.dxvkFolder : engine.payloadRoot(.dxvk) else {
            throw DXVKError.payloadMissing
        }
        try FileManager.default.replaceDLLs(
            in: bottle.url.appending(path: "drive_c").appending(path: "windows").appending(path: "system32"),
            withContentsIn: payload.appending(path: "x64")
        )
        try FileManager.default.replaceDLLs(
            in: bottle.url.appending(path: "drive_c").appending(path: "windows").appending(path: "syswow64"),
            withContentsIn: payload.appending(path: "x32")
        )
        reconcileDXGIForDXVK(prefixRoot: bottle.url, engine: engine)
    }

    /// Reconciles the prefix's `dxgi.dll` with the GPTK payload state, keyed on
    /// whether that payload is deployed.
    ///
    /// DXVK-macOS ships no `dxgi.dll`, so ``enableDXVK(bottle:)`` never
    /// overwrites one and whatever the prefix already holds stays behind the
    /// `n,b` override. Which copy is correct depends entirely on what the
    /// builtin is right now:
    ///
    /// - Payload deployed: the builtin is Apple's D3DMetal forwarder, which
    ///   cannot pair with DXVK's `d3d11`. The prefix needs Wine's own clean
    ///   dxgi from the store, marker-stripped so the loader takes it as a true
    ///   native PE.
    /// - Payload absent: the builtin is Wine's own, which is the pairing DXVK
    ///   is written against, so any native copy in the prefix is residue and
    ///   must go.
    ///
    /// The store outlives an engine install but the deployed payload does not,
    /// so a populated `originals/` alone does not mean the forwarder is in
    /// place. Keying on the payload rather than the store is what makes the
    /// stale-store case (originals from a previous engine, payload gone) take
    /// the removal path instead of deploying a dxgi the current runtime never
    /// shipped.
    ///
    /// The deployed branch still sweeps `syswow64`: GPTK forwards only the
    /// 64-bit builtin, so the 32-bit one is wine's own and DXMT residue there
    /// is just as wrong as without the payload. The sweep is scoped to
    /// `syswow64` on purpose; the stripped system32 copy is native by design,
    /// and a both-arch sweep would delete it on every launch.
    static func reconcileDXGIForDXVK(
        prefixRoot: URL,
        gptkOriginalsDXGI: URL = GPTKImporter.storeFolder
            .appending(path: "originals").appending(path: "dxgi.dll"),
        gptkPayloadIsDeployed: Bool = GPTKImporter.isDeployed(),
        engine: WineEngine = .managed
    ) {
        // `engine.libraryURL` is the `…/Wine/lib` `libraryFolder` resolved
        // into for the managed tree; for an external engine it is the
        // external tree's own lib, so a builtin restore never reads managed
        // files. The deployed-payload question is answered from the engine,
        // not the managed store.
        let wineLib = engine.libraryURL
        let payloadDeployed = engine.isManaged
            ? gptkPayloadIsDeployed
            : engine.payloadRoot(.d3dMetal) != nil
        guard payloadDeployed else {
            removeStaleNativeDXGI(prefixRoot: prefixRoot, wineLibURL: wineLib)
            return
        }
        removeStaleNativeDXGI(prefixRoot: prefixRoot, wineLibURL: wineLib, directories: ["syswow64"])
        // The clean-dxgi restore only exists for the managed runtime: the
        // backup lives in the managed GPTK store, which an external launch
        // must not borrow from. With no backup the deploy is a no-op.
        deployCleanDXGI(
            prefixRoot: prefixRoot,
            from: engine.isManaged ? gptkOriginalsDXGI : prefixRoot.appending(path: ".nonexistent")
        )
    }

    /// Removes a native `dxgi.dll` the prefix must not keep under DXVK.
    ///
    /// DXVK-macOS ships no `dxgi.dll`, so ``enableDXVK(bottle:)`` never
    /// overwrites one. After a bottle has launched under DXMT, its system
    /// directories hold DXMT's *native* dxgi, and a DXVK launch then pairs
    /// DXVK's `d3d11` with DXMT's `dxgi` under the `n,b` override. That mix
    /// cannot create window swapchains: Chromium clients fail with
    /// `DXGI_ERROR_UNSUPPORTED` and run with no window at all. Removing the
    /// leftover lets the `,b` half of the override load the builtin, which is
    /// the pairing DXVK is written against.
    ///
    /// Both arches are swept, because a DXMT launch writes both and a 32-bit
    /// title otherwise keeps the bad pairing. A builtin-marked file is never
    /// touched: that is wine's own fake DLL, exactly what DXVK expects to
    /// defer to, and leaving it in place is what keeps this off the
    /// per-launch prefix-mutation path.
    ///
    /// Whether removal is the right answer at all is decided by
    /// ``reconcileDXGIForDXVK(prefixRoot:gptkOriginalsDXGI:gptkPayloadIsDeployed:libraryFolder:)``,
    /// which owns the payload predicate and picks the `directories` to sweep.
    static func removeStaleNativeDXGI(
        prefixRoot: URL,
        wineLibURL: URL = WhiskyWineInstaller.binFolder.deletingLastPathComponent().appending(path: "lib"),
        directories: Set<String> = ["system32", "syswow64"]
    ) {
        let fileManager = FileManager.default
        let builtinDirs = ["system32": "x86_64-windows", "syswow64": "i386-windows"]
        for (dir, arch) in builtinDirs where directories.contains(dir) {
            let dxgi = prefixRoot.appending(path: "drive_c").appending(path: "windows")
                .appending(path: dir).appending(path: "dxgi.dll")
            guard fileManager.fileExists(atPath: dxgi.path(percentEncoded: false)),
                  (try? isNativePE(dxgi)) == true
            else { continue }
            do {
                try fileManager.removeItem(at: dxgi)
                Logger.wineKit.info("Removed stale native dxgi.dll from \(dir, privacy: .public)")
            } catch {
                Logger.wineKit.warning(
                    "Could not remove stale native dxgi.dll: \(error.localizedDescription, privacy: .public)"
                )
                continue
            }
            // The removal must not leave the slot empty. Wine's loader only reaches a
            // builtin through its system32 placeholder (ntdll/loader.c
            // find_builtin_without_file refuses every non-16-bit DLL that has no
            // file), so with nothing here `LoadLibrary("dxgi.dll")` fails outright
            // and Chromium's GPU process cannot bring up D3D11. wineboot would
            // reinstall the placeholder on the next prefix update, but a runtime
            // whose wine.inf matches the prefix stamp never runs one. Put back the
            // runtime's own marked copy, which is what wineboot installs.
            let builtin = wineLibURL
                .appending(path: "wine").appending(path: arch).appending(path: "dxgi.dll")
            guard fileManager.fileExists(atPath: builtin.path(percentEncoded: false)) else {
                Logger.wineKit.warning("No builtin dxgi.dll to restore into \(dir, privacy: .public)")
                continue
            }
            do {
                try fileManager.copyItem(at: builtin, to: dxgi)
                Logger.wineKit.info("Restored builtin dxgi.dll placeholder into \(dir, privacy: .public)")
            } catch {
                Logger.wineKit.warning(
                    "Could not restore builtin dxgi.dll: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Strips the "Wine builtin DLL" marker at offset 0x40 from a PE file.
    private static func stripBuiltinMarker(at fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return }
        let handle = try FileHandle(forUpdating: fileURL)
        defer { try? handle.close() }
        let dosCode: [UInt8] = [
            0x0E, 0x1F, 0xBA, 0x0E, 0x00, 0xB4, 0x09, 0xCD,
            0x21, 0xB8, 0x01, 0x4C, 0xCD, 0x21, 0x90, 0x90
        ]
        try handle.seek(toOffset: 0x40)
        try handle.write(contentsOf: Data(dosCode))
    }

    /// Deploys Wine's backed-up clean `dxgi.dll` into the prefix, with the
    /// builtin marker stripped so the loader accepts it as a true native PE.
    ///
    /// Only `system32` is written: GPTK deploys forwarders into
    /// `wine/x86_64-windows` only, so the 32-bit builtin is still Wine's own
    /// and the stored 64-bit original has no business in `syswow64`.
    ///
    /// This runs on every DXVK launch, so a prefix that already holds the
    /// stripped original is left untouched rather than copied and patched
    /// again.
    static func deployCleanDXGI(prefixRoot: URL, from gptkOriginalsDXGI: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: gptkOriginalsDXGI.path(percentEncoded: false)) else { return }

        let sys32DXGI = prefixRoot.appending(path: "drive_c").appending(path: "windows")
            .appending(path: "system32").appending(path: "dxgi.dll")
        if isStrippedCopy(sys32DXGI, of: gptkOriginalsDXGI) {
            return
        }
        do {
            try fileManager.installFile(at: sys32DXGI, from: gptkOriginalsDXGI)
            try stripBuiltinMarker(at: sys32DXGI)
        } catch {
            Logger.wineKit.warning(
                "Could not deploy clean dxgi.dll into prefix: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Whether `deployed` is already what ``deployCleanDXGI(prefixRoot:from:)``
    /// would write: a native PE that matches `original` byte for byte outside
    /// the 16-byte marker window at 0x40, the only bytes the strip rewrites.
    private static func isStrippedCopy(_ deployed: URL, of original: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: deployed.path(percentEncoded: false)),
              (try? isNativePE(deployed)) == true,
              let existing = try? Data(contentsOf: deployed),
              let source = try? Data(contentsOf: original),
              existing.count == source.count,
              existing.count >= 0x50
        else { return false }
        let window = 0x40 ..< 0x50
        return existing[..<window.lowerBound] == source[..<window.lowerBound]
            && existing[window.upperBound...] == source[window.upperBound...]
    }

    /// Errors thrown by ``enableDXVK(bottle:engine:)``.
    public enum DXVKError: LocalizedError, Equatable {
        /// The selected engine has no usable DXVK payload. An external engine
        /// must carry its own `DXVK/` tree; the managed payload is never
        /// borrowed for an external launch.
        case payloadMissing

        public var errorDescription: String? {
            switch self {
            case .payloadMissing:
                "The selected Wine engine has no DXVK payload"
            }
        }
    }

    /// Errors thrown by ``enableDXMT(bottle:)``.
    public enum DXMTError: LocalizedError, Equatable {
        /// The installed runtime has no usable DXMT payload — either absent
        /// (a runtime predating the DXMT payload, or a damaged/truncated
        /// install) or the older builtin-variant payload that cannot be
        /// activated per-bottle.
        case payloadMissing

        public var errorDescription: String? {
            switch self {
            case .payloadMissing:
                String(localized: "wine.dxmt.error.payloadMissing")
            }
        }
    }

    /// DXMT's D3D translation trio — native PEs loaded from the prefix under the
    /// `n,b` override.
    static let dxmtNativeTrio = ["d3d11.dll", "dxgi.dll", "d3d10core.dll"]

    /// The DXMT files deployed into a bottle: the native D3D trio plus
    /// `winemetal.dll`. `winemetal.dll` is the builtin-marked redirect whose
    /// import resolves to the runtime's `winemetal.dll` builtin in `lib/wine`.
    /// The NVIDIA extras (nvapi64/nvngx) in the payload are deliberately not
    /// deployed — DXMT's vendor spoofing is out of scope.
    static let dxmtPrefixDLLs = dxmtNativeTrio + ["winemetal.dll"]

    /// Whether the installed runtime carries a DXMT payload that can actually be
    /// activated per-bottle: present **and** the *native* variant. A
    /// builtin-marked trio (the older runtime layout) is silently ignored by the
    /// loader in favor of wined3d, so it does not count as available. Used to
    /// gate the DXMT backend in the pickers. The x64 `d3d11.dll` is sampled as
    /// the trio's representative (the runtime assembles all three together); the
    /// per-launch ``enableDXMT(payloadRoot:prefixRoot:)`` guard verifies the whole
    /// trio.
    public static func isDXMTRuntimeNative() -> Bool {
        isDXMTRuntimeNative(payloadRoot: dxmtFolder)
    }

    /// Capability check against an explicit payload root. Factored out so the
    /// gate can be tested against temporary fixtures (mirrors the
    /// ``enableDXMT(payloadRoot:prefixRoot:)`` seam).
    static func isDXMTRuntimeNative(payloadRoot: URL) -> Bool {
        let d3d11 = payloadRoot.appending(path: "x64").appending(path: "d3d11.dll")
        guard FileManager.default.fileExists(atPath: d3d11.path(percentEncoded: false)) else { return false }
        return (try? isNativePE(d3d11)) ?? false
    }

    /// Returns `true` when the PE at `url` is a markerless *native* DLL — i.e. its
    /// DOS stub does not carry winebuild's "Wine builtin DLL" signature in the 16
    /// bytes at offset 0x40. A builtin-marked copy placed in the prefix is ignored
    /// by the loader, which redirects to the `lib/wine` builtin (wined3d) instead.
    /// A file too short to hold those 16 bytes is treated as **not** native
    /// (fail-closed): a truncated or corrupt payload must not be deployed as if it
    /// were a working native DLL — that would resurrect the silent wined3d
    /// fallback this guard exists to prevent.
    static func isNativePE(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0x40)
        guard let marker = try handle.read(upToCount: 16), marker.count == 16 else {
            return false
        }
        return marker != Data("Wine builtin DLL".utf8)
    }

    /// Places the per-bottle files a backend needs in the prefix before launch.
    ///
    /// DXMT goes first: if launcher auto-DXVK also fires in `runProgram`, DXVK's
    /// file copy deterministically wins, matching the override-layer order where
    /// launcher-managed entries land after bottle-managed ones.
    @MainActor
    private static func prepareBackendPrefix(
        _ backend: GraphicsBackend, bottle: Bottle, engine: WineEngine = .managed
    ) throws {
        switch backend {
        case .dxmt:
            try enableDXMT(bottle: bottle, engine: engine)
        case .d3dMetal, .dxvk, .wined3d, .recommended:
            break
        }
    }

    /// Opts a bottle in or out of D3DMetal's DLSS-to-MetalFX path, per
    /// ``BottleSettings/metalFX`` and the backend the launch actually resolved
    /// to.
    ///
    /// The bridge itself is a builtin in the shared Wine tree, so it cannot be
    /// installed per bottle. What can is the `system32` entry the loader needs
    /// before it will look in the builtin directory at all: without one,
    /// `LoadLibrary("nvngx.dll")` fails with `ERROR_MOD_NOT_FOUND` however
    /// complete the tree is. So the placeholder is the switch: present means a
    /// game can reach MetalFX, absent means the bridge is inert.
    ///
    /// Only D3DMetal implements the DLSS entry points behind it, so every other
    /// backend clears, setting or no setting. Otherwise a bottle switched away
    /// from D3DMetal with MetalFX still on keeps a placeholder for a bridge
    /// nothing in that prefix can answer, and a DLSS-aware game reaches it under
    /// a backend it was never meant for.
    ///
    /// - Parameters:
    ///   - bottle: The ``Bottle`` whose opt-in state to apply.
    ///   - backend: The backend the games this launch concerns resolve to: the
    ///     program's own, or the bottle's games' when a launcher is started.
    ///   - libraryFolder: The runtime tree holding the bridge.
    ///
    /// - Note: Called by `runProgram` for every launch, in both directions, so
    ///   turning the setting off or switching backend takes effect on the next
    ///   launch without the user having to repair anything.
    @MainActor
    public static func applyMetalFX(
        bottle: Bottle,
        backend: GraphicsBackend,
        libraryFolder: URL = WhiskyWineInstaller.libraryFolder
    ) {
        if backend == .d3dMetal, bottle.settings.metalFX {
            GPTKImporter.seedMetalFXBridgePlaceholder(inBottle: bottle.url, fromLibraryFolder: libraryFolder)
            seedNGXModelConfig(inBottle: bottle.url)
        } else {
            GPTKImporter.clearMetalFXBridgePlaceholder(inBottle: bottle.url)
        }
    }

    /// Where NGX keeps the manifest its updater reads, which a real NVIDIA driver
    /// would have written.
    static let ngxModelConfigPath = ["drive_c", "ProgramData", "NVIDIA", "NGX", "models"]

    /// Writes the NGX manifest a driver install would leave behind.
    ///
    /// Streamline opens this before it does anything else and logs a pair of
    /// errors per launch when it is missing:
    ///
    ///     [streamline][error] File 'C:\ProgramData/NVIDIA/NGX/models/nvngx_config.txt' does not exist
    ///     [streamline][error] readServerManifest: Failed to open manifest file
    ///
    /// Only the over-the-air updater reads what is inside, and that updater
    /// (`nvngx_update.exe`) does not exist here either, so the contents matter
    /// less than the file existing. Left alone once written, so a real one from a
    /// driver install or a user's own edit survives.
    ///
    /// - Parameter bottle: The bottle whose prefix to seed.
    static func seedNGXModelConfig(inBottle bottle: URL) {
        let fileManager = FileManager.default
        let folder = ngxModelConfigPath.reduce(bottle) { $0.appending(path: $1) }
        let config = folder.appending(path: "nvngx_config.txt")
        guard !fileManager.fileExists(atPath: config.path(percentEncoded: false)) else { return }
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try? "[global]\nversion = 1\n".write(to: config, atomically: true, encoding: .utf8)
    }

    /// Installs DXMT into a bottle so its Direct3D-11-to-Metal layer is used.
    ///
    /// Copies the native D3D translation trio (`d3d11`, `dxgi`, `d3d10core`) and
    /// `winemetal.dll` from the runtime's DXMT payload into the bottle's system
    /// directories — the same per-bottle, prefix-local model as ``enableDXVK``,
    /// selected by the `n,b` overrides from ``DLLOverrideResolver/dxmtPreset(builtinD3D12IsD3DMetal:)``.
    /// The runtime ships DXMT's `winemetal.dll` builtin (paired with its
    /// `winemetal.so` unixlib) in `lib/wine`, so this method never touches the
    /// shared Wine tree; the prefix `winemetal.dll` is the builtin-marked
    /// redirect that resolves the trio's import to that builtin.
    ///
    /// - Parameter bottle: The ``Bottle`` to install DXMT into.
    /// - Throws: ``DXMTError/payloadMissing`` when the runtime has no usable
    ///   (present and native) DXMT payload, or a `CocoaError` if a copy fails.
    ///
    /// - Note: This is automatically called by `runProgram` when the effective
    ///   graphics backend is `.dxmt`.
    @MainActor
    public static func enableDXMT(bottle: Bottle, engine explicitEngine: WineEngine? = nil) throws {
        let engine = try explicitEngine ?? Self.engine(for: bottle)
        guard let payload = engine.isManaged ? Wine.dxmtFolder : engine.payloadRoot(.dxmt) else {
            throw DXMTError.payloadMissing
        }
        try enableDXMT(payloadRoot: payload, prefixRoot: bottle.url)
    }

    /// Performs the DXMT installation against explicit roots. Factored out of
    /// ``enableDXMT(bottle:)`` so the file placement can be tested against
    /// temporary directories (mirrors `enableDXVK`'s prefix-local copy).
    static func enableDXMT(payloadRoot: URL, prefixRoot: URL) throws {
        let fileManager = FileManager.default
        let x64Payload = payloadRoot.appending(path: "x64")
        let x32Payload = payloadRoot.appending(path: "x32")

        let windowsDir = prefixRoot.appending(path: "drive_c").appending(path: "windows")
        let system32 = windowsDir.appending(path: "system32")
        let syswow64 = windowsDir.appending(path: "syswow64")
        let deploy32Bit = fileManager.fileExists(atPath: syswow64.path(percentEncoded: false))

        // Validate every source BEFORE touching the prefix, and require the whole
        // trio to be the native variant. A damaged runtime (a file missing or
        // truncated) or the older builtin-variant payload (which the loader would
        // ignore in favor of wined3d) must fail with the actionable payloadMissing
        // error rather than half-deploy, or launch a bottle that silently isn't
        // using DXMT.
        var sources = dxmtPrefixDLLs.map { x64Payload.appending(path: $0) }
        if deploy32Bit {
            sources += dxmtPrefixDLLs.map { x32Payload.appending(path: $0) }
        }
        let allPresent = sources.allSatisfy { fileManager.fileExists(atPath: $0.path(percentEncoded: false)) }
        let trioIsNative = dxmtNativeTrio.allSatisfy {
            (try? isNativePE(x64Payload.appending(path: $0))) == true
        }
        guard allPresent, trioIsNative else {
            throw DXMTError.payloadMissing
        }

        for name in dxmtPrefixDLLs {
            try fileManager.installFileIfContentDiffers(
                at: system32.appending(path: name),
                from: x64Payload.appending(path: name)
            )
        }

        // 32-bit half: only when the prefix actually has a syswow64 tree.
        if deploy32Bit {
            for name in dxmtPrefixDLLs {
                try fileManager.installFileIfContentDiffers(
                    at: syswow64.appending(path: name),
                    from: x32Payload.appending(path: name)
                )
            }
        }
    }
}

// MARK: - Environment Key Validation

extension Wine {
    /// Reinitializes a Wine prefix to repair missing user directories.
    ///
    /// This method runs `wineboot --init` to reinitialize the Wine prefix,
    /// which creates any missing user profile directories that may have been
    /// deleted or never properly created during initial bottle setup.
    ///
    /// Use this method when winetricks or other dependency installations fail
    /// due to missing `%AppData%` or user profile directories.
    ///
    /// - Parameter bottle: The ``Bottle`` whose prefix should be repaired.
    /// - Throws: An error if wineboot fails to initialize the prefix.
    ///
    /// - Note: This operation may take several seconds as Wine reinitializes
    ///   the prefix and creates missing directories.
    @discardableResult
    @MainActor
    public static func repairPrefix(bottle: Bottle) async throws -> String {
        logger.info("Repairing Wine prefix for bottle '\(bottle.settings.name)'")
        return try await runWine(["wineboot", "--init"], bottle: bottle)
    }

    /// Checks if an environment variable key is a valid POSIX shell identifier.
    ///
    /// Valid names must start with an ASCII letter or underscore, followed by
    /// any combination of ASCII letters, digits, or underscores.
    /// This prevents shell injection through malicious environment variable keys.
    ///
    /// - Note: Uses explicit ASCII checks rather than Swift's Unicode-aware
    ///   `isLetter`/`isNumber` methods, since POSIX shells only accept ASCII
    ///   identifiers (`[A-Za-z_][A-Za-z0-9_]*`).
    ///
    /// - Parameter key: The environment variable name to validate.
    /// - Returns: `true` if the key is safe to use in shell commands.
    static func isValidEnvKey(_ key: String) -> Bool {
        guard let first = key.first, isAsciiLetter(first) || first == "_" else { return false }
        return key.allSatisfy { isAsciiLetter($0) || isAsciiDigit($0) || $0 == "_" }
    }

    /// Checks if a character is an ASCII letter (A-Z, a-z).
    static func isAsciiLetter(_ char: Character) -> Bool {
        guard let ascii = char.asciiValue else { return false }
        return (ascii >= 65 && ascii <= 90) || (ascii >= 97 && ascii <= 122) // A-Z or a-z
    }

    /// Checks if a character is an ASCII digit (0-9).
    static func isAsciiDigit(_ char: Character) -> Bool {
        guard let ascii = char.asciiValue else { return false }
        return ascii >= 48 && ascii <= 57 // 0-9
    }
}

/// Errors that can occur during Wine interface operations.
enum WineInterfaceError: Error {
    /// The response from Wine was invalid or could not be parsed.
    case invalidResponse
}

// MARK: - Logging Support

public extension Wine {
    /// Maximum size of a single Whisky log file written by Wine process logging.
    ///
    /// Policy: cap each individual log at 20 MiB.
    static let maxLogFileBytes: Int64 = 20 * 1_024 * 1_024

    /// Maximum total size allowed for all Whisky log files in `logsFolder`.
    ///
    /// Policy: cap total disk usage of Whisky's log directory at 200 MiB.
    static let maxLogsFolderBytes: Int64 = 200 * 1_024 * 1_024

    /// Marker appended once when file logging begins truncation.
    ///
    /// - Important: This marker is written at most once per log file and counts toward `maxLogFileBytes`.
    static let logTruncationMarker = "\n[Whisky] Log truncated: reached 20 MiB cap; further output discarded.\n"

    /// The URL to the directory where Wine process logs are stored.
    ///
    /// Logs are stored in `~/Library/Logs/{bundle-identifier}/` with ISO 8601
    /// timestamps as filenames.
    static let logsFolder = FileManager.default.urls(
        for: .libraryDirectory, in: .userDomainMask
    )[0].appending(path: "Logs").appending(path: Bundle.whiskyBundleIdentifier)

    /// Enforces log retention policy by deleting the oldest `.log` files until total size is under the limit.
    ///
    /// - Important: This method only operates on the provided folder and only deletes regular files with a `.log`
    ///   extension. It is intentionally best-effort: errors are logged but do not throw.
    static func enforceLogRetention(in folder: URL, maxTotalBytes: Int64) {
        do {
            let keys: [URLResourceKey] = [
                .isRegularFileKey,
                .contentModificationDateKey,
                .creationDateKey,
                .fileSizeKey
            ]
            let urls = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )

            struct LogFile {
                let url: URL
                let size: Int64
                let date: Date
            }

            var files: [LogFile] = []
            files.reserveCapacity(urls.count)

            for url in urls {
                guard url.pathExtension.lowercased() == "log" else { continue }
                let values = try url.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true else { continue }
                let size = Int64(values.fileSize ?? 0)
                let date = values.contentModificationDate ?? values.creationDate ?? .distantPast
                files.append(LogFile(url: url, size: size, date: date))
            }

            var total: Int64 = files.reduce(0) { $0 + $1.size }
            guard total > maxTotalBytes else { return }

            // Oldest first
            files.sort { $0.date < $1.date }

            for file in files {
                guard total > maxTotalBytes else { break }
                do {
                    try FileManager.default.removeItem(at: file.url)
                    total -= file.size
                } catch {
                    let logPath = file.url.path(percentEncoded: false)
                    let errorDescription = error.localizedDescription
                    Logger.wineKit.error(
                        "Failed to remove log \(logPath, privacy: .public): \(errorDescription, privacy: .public)"
                    )
                }
            }
        } catch {
            let folderPath = folder.path(percentEncoded: false)
            let errorDescription = error.localizedDescription
            Logger.wineKit.error(
                "Failed to enforce retention in \(folderPath, privacy: .public): \(errorDescription, privacy: .public)"
            )
        }
    }

    /// Creates a new file handle for logging Wine process output.
    ///
    /// Each call creates a new log file with the current timestamp.
    /// The log directory is created if it doesn't exist.
    ///
    /// - Returns: A `FileHandle` open for writing to the new log file.
    /// - Throws: An error if the log directory or file cannot be created.
    static func makeFileHandle() throws -> FileHandle {
        let (handle, _) = try makeFileHandleWithURL()
        return handle
    }

    /// Creates a new file handle for logging and returns both the handle and the log file URL.
    ///
    /// This variant is used when the caller needs to track the log file location
    /// (e.g., for post-run crash classification).
    ///
    /// - Returns: A tuple of the open `FileHandle` and its log file `URL`.
    /// - Throws: An error if the log directory or file cannot be created.
    static func makeFileHandleWithURL() throws -> (FileHandle, URL) {
        try makeLogFile(in: logsFolderOverride ?? logsFolder, date: .now)
    }

    /// The folder ``makeFileHandleWithURL()`` creates logs in, instead of ``logsFolder``,
    /// for as long as a task binds it. Tests bind a temporary folder of their own, so the
    /// helper runs they make never write under `~/Library/Logs`, and test processes
    /// running in parallel never share a logs folder.
    @TaskLocal internal static var logsFolderOverride: URL?

    @TaskLocal internal static var wineserverSyncRunner: (@Sendable (
        _ args: [String],
        _ environment: [String: String],
        _ timeout: TimeInterval
    ) throws -> Void)?
    @TaskLocal internal static var wineserverAsyncRunner: (@MainActor @Sendable (
        _ args: [String],
        _ bottle: Bottle
    ) async throws -> String)?

    /// Creates a new log file in `folder`, named for `date`, and opens it for writing.
    ///
    /// The name is the ISO 8601 timestamp to the millisecond, with `-2`, `-3` and so on
    /// appended while that name is taken, and the file is only ever created, never
    /// replaced. Names used to stop at the second and the file was written atomically,
    /// so a helper started in the same second as a launch, such as the DLL override
    /// import, replaced the launch's log: the program went on writing to a file that
    /// was no longer on disk, and the log recorded for the run held only the helper's
    /// output.
    ///
    /// - Parameters:
    ///   - folder: The directory to create the log in. It is created if missing.
    ///   - date: The time the log is named for.
    /// - Returns: A tuple of the open `FileHandle` and its log file `URL`.
    /// - Throws: An error if the log directory or file cannot be created.
    internal static func makeLogFile(in folder: URL, date: Date) throws -> (FileHandle, URL) {
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        // Enforce retention before creating a new log file.
        // This is best-effort and only impacts Whisky's own log directory.
        enforceLogRetention(in: folder, maxTotalBytes: maxLogsFolderBytes)

        let timestamp = date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        for attempt in 1 ... maxLogNameAttempts {
            let name = attempt == 1 ? timestamp : "\(timestamp)-\(attempt)"
            let fileURL = folder.appending(path: name).appendingPathExtension("log")
            if let handle = try createNewFile(at: fileURL) {
                return (handle, fileURL)
            }
        }
        throw POSIXError(.EEXIST)
    }

    /// How many names ``makeLogFile(in:date:)`` tries for one timestamp.
    private static let maxLogNameAttempts = 100

    /// Creates a file at `url` and opens it for writing, or returns `nil` when
    /// something already exists there. `O_EXCL` makes the check and the creation
    /// one step, so two writers can never end up sharing a path.
    private static func createNewFile(at url: URL) throws -> FileHandle? {
        let (descriptor, error) = url.withUnsafeFileSystemRepresentation { path -> (Int32, Int32) in
            guard let path else {
                return (-1, EINVAL)
            }
            let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
            return (descriptor, descriptor < 0 ? errno : 0)
        }
        if descriptor >= 0 {
            return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }
        guard error == EEXIST else {
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        return nil
    }

    /// Classifies the output from a Wine process run for crash patterns.
    ///
    /// Reads the head and the tail of the log, not the tail alone: missing-DLL
    /// (`import_dll`) and backend-init failures are head-of-log events, and a
    /// long session buries them under hours of output a tail-only window never
    /// sees. Runs on a background task to avoid blocking the UI.
    ///
    /// - Parameters:
    ///   - logFileURL: URL to the Wine log file to analyze.
    ///   - exitCode: The Wine process exit code.
    ///   - classifier: Optional pre-configured classifier. If `nil`, creates one
    ///     with default patterns.
    /// - Returns: A ``CrashDiagnosis`` if the log was readable, or `nil` on failure.
    static func classifyLastRun(
        logFileURL: URL,
        exitCode: Int32,
        classifier: CrashClassifier? = nil
    ) async -> CrashDiagnosis? {
        await Task.detached(priority: .utility) {
            guard let logText = try? classificationWindow(of: logFileURL), !logText.isEmpty else {
                return nil
            }
            let resolvedClassifier = classifier ?? CrashClassifier()
            return resolvedClassifier.classify(log: logText, exitCode: exitCode)
        }.value
    }

    /// The head and tail of a log, joined into the window classification reads.
    private nonisolated static func classificationWindow(of logFileURL: URL) throws -> String? {
        let maxTailBytes = 256 * 1_024
        let maxHeadBytes = 64 * 1_024
        let maxTailLines = 500
        let maxHeadLines = 200

        let handle = try FileHandle(forReadingFrom: logFileURL)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()

        if end <= UInt64(maxHeadBytes + maxTailBytes) {
            try handle.seek(toOffset: 0)
            let data = try handle.readToEnd() ?? Data()
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count <= maxHeadLines + maxTailLines {
                return text
            }
            return (lines.prefix(maxHeadLines) + lines.suffix(maxTailLines)).joined(separator: "\n")
        }

        try handle.seek(toOffset: 0)
        let headData = try handle.read(upToCount: maxHeadBytes) ?? Data()
        var head = String(data: headData, encoding: .utf8) ?? ""
        // Drop the trailing partial line of the head window.
        if let lastNewline = head.lastIndex(of: "\n") {
            head = String(head[..<lastNewline])
        }
        let headLines = head
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(maxHeadLines)

        try handle.seek(toOffset: end - UInt64(maxTailBytes))
        let tailData = try handle.readToEnd() ?? Data()
        var tail = String(data: tailData, encoding: .utf8) ?? ""
        // Drop the leading partial line of the tail window.
        if let firstNewline = tail.firstIndex(of: "\n") {
            tail = String(tail[tail.index(after: firstNewline)...])
        }
        let tailLines = tail
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(maxTailLines)

        return (headLines + tailLines).joined(separator: "\n")
    }
}

// swiftlint:enable type_body_length
