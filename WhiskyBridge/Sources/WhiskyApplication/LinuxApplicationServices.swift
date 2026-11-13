//
//  LinuxApplicationServices.swift
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
import WhiskyCore

/// Portable POSIX/Linux host service adapter for file operations, tool discovery and optional runtime drivers.
@MainActor
public final class LinuxApplicationServices: NativeApplicationServices {
    public typealias FileOpener = @Sendable (URL) throws -> Void
    public typealias WineserverProbe = @Sendable (LinuxWineHost, URL) async throws -> Bool

    let runtimeService: RuntimeService?
    private let wineHost: LinuxWineHost?
    let engineStore: LinuxWineEngineStore?
    private let bottleCreation: LinuxBottleCreationService?
    private let winetricks: LinuxWinetricksService
    private let jobs: BridgeJobStore?
    private let openFile: FileOpener
    let wineserverProbe: WineserverProbe
    private let searchPaths: [URL]
    private let picker: LinuxFilePicker
    private let terminals: LinuxTerminalService
    private let preferences: PreferencesService?
    private let desktop: LinuxDesktopService
    private let wineSetup: LinuxWineSetupService?
    private let shutdownContainers: (() throws -> [URL])?
    private let finalObservation: (() async -> Void)?

    public init(
        runtime: RuntimeService? = nil,
        searchPaths: [URL]? = nil,
        openFile: FileOpener? = nil,
        preferences: PreferencesService? = nil,
        wineRuntimeURL: URL? = nil,
        jobs: BridgeJobStore? = nil,
        wineSetup: LinuxWineSetupService? = nil,
        engineStore: LinuxWineEngineStore? = nil,
        shutdownContainers: (() throws -> [URL])? = nil,
        finalObservation: (() async -> Void)? = nil,
        host: LinuxWineHost? = nil,
        wineserverProbe: WineserverProbe? = nil
    ) {
        runtimeService = runtime
        self.wineSetup = wineSetup
        self.engineStore = engineStore
        self.shutdownContainers = shutdownContainers
        self.finalObservation = finalObservation
        self.wineserverProbe = wineserverProbe ?? { host, container in
            try await host.probeServer(prefix: container)
        }
        let resolvedHost = host ?? wineRuntimeURL.flatMap { LinuxWineHost(runtimeURL: $0) }
        wineHost = resolvedHost
        if let engineStore {
            bottleCreation = LinuxBottleCreationService(engineStore: engineStore, jobs: jobs)
        } else {
            bottleCreation = resolvedHost.flatMap { LinuxBottleCreationService(host: $0, jobs: jobs) }
        }
        self.jobs = jobs
        self.preferences = preferences
        let paths = searchPaths ?? Self.defaultSearchPaths()
        self.searchPaths = paths
        let bundled = Bundle.main.executableURL.map { [$0.deletingLastPathComponent()] } ?? []
        let managedRuntime = resolvedHost?.runtimeURL ?? engineStore?.managedEngine().runtimeURL
        let wineBin = managedRuntime.map { [$0.appendingPathComponent("bin")] } ?? []
        winetricks = LinuxWinetricksService(
            host: resolvedHost,
            engineStore: engineStore,
            jobs: jobs,
            searchPaths: bundled + wineBin + paths
        )
        terminals = LinuxTerminalService(searchPaths: paths, environment: ProcessInfo.processInfo.environment)
        desktop = LinuxDesktopService(environment: ProcessInfo.processInfo.environment, searchPaths: paths)
        picker = LinuxFilePicker(searchPaths: bundled + paths)
        self.openFile = openFile ?? Self.xdgOpen
    }

    private var hasWineCapability: Bool {
        wineHost != nil || engineStore != nil
    }

    public var capabilities: [String] {
        var values = ["system.files", "system.picker", "system.terminal", "system.desktop", "programs.shortcut"]
        if wineSetup != nil || bottleCreation != nil {
            values.append("setup")
        }
        if engineStore != nil {
            values.append("wine.engines")
        }
        if hasWineCapability {
            values += winetricks.capabilities
            values.append("processes.read")
        }
        if bottleCreation != nil {
            values.append("bottle.tools")
            values.append("wine.configuration")
        }
        if bottleCreation?.canCreate == true {
            values.append("bottle.create")
        }
        if hasWineCapability, jobs != nil {
            values.append("programs.launch")
        }
        if runtimeService != nil {
            values += RuntimeService.capabilities
        }
        return values
    }

    public var methods: [String] {
        var values = [
            "system.reveal", "system.open", "system.resources", "system.terminals",
            "bottle.tools", "bottle.cleanCache"
        ] + LinuxFilePicker.methods + LinuxDesktopService.methods
        if engineStore != nil {
            values += Self.engineMethods
        }
        values += wineSetup?.methods ?? []
        if hasWineCapability {
            values += winetricks.methods
        }
        if bottleCreation != nil, !values.contains("setup.status") {
            values.append("setup.status")
        }
        if bottleCreation?.canCreate == true {
            values.append("bottle.create")
        }
        if hasWineCapability, jobs != nil {
            values.append("programs.run")
        }
        if runtimeService != nil {
            values += RuntimeService.methods
        }
        return values
    }

    public func configurationChanged(
        _ field: ConfigurationField,
        value: ConfigurationValue,
        values: [String: ConfigurationValue],
        container: URL
    ) async throws {
        let resolved = try resolveContainerHost(for: container, missingCapability: true)
        let lease = try resolved.engine.map { try engineStore!.acquireSharedLease(for: $0.id) }
        defer { lease?.release() }
        let host = resolved.host
        if field.id == "windowsVersion", case let .text(raw) = value {
            let version = raw == "winxp" ? "winxp64" : raw
            let result = try await host.run(
                host.loader,
                arguments: ["winecfg", "-v", version],
                prefix: container,
                environment: ["WINEDEBUG": "-all"],
                timeout: .seconds(30)
            )
            guard !result.timedOut, result.status == 0 else {
                throw BridgeFailure(
                    "operation_failed",
                    "Could not change the Windows version (Wine exit \(result.status))"
                )
            }
            return
        }
        var updated = values
        updated[field.id] = value
        try await LinuxWineConfiguration.importRegistry(
            LinuxWineConfiguration.virtualDesktop(updated), container: container, host: host
        )
    }

    public func call(
        _ method: String,
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) async throws -> JSONValue {
        guard methods.contains(method) else {
            throw BridgeFailure("method_unavailable", "Native method is unavailable")
        }
        if Self.engineMethods.contains(method) {
            return try await callEngineMethod(method, params: params, workspace: workspace)
        }
        if LinuxDesktopService.methods.contains(method) {
            return try await desktop.call(method, params: params, workspace: workspace)
        }
        switch method.prefix(while: { $0 != "." }) {
        case "system":
            if LinuxFilePicker.methods.contains(method) {
                return try await picker.call(method, params: params)
            }
            return try systemCall(method, params: params, workspace: workspace)
        case "bottle":
            if method == "bottle.create" {
                guard let bottleCreation, bottleCreation.canCreate else {
                    throw BridgeFailure("method_unavailable", "Bottle creation is unavailable")
                }
                return try bottleCreation.create(params: params, workspace: workspace)
            }
            if method == "bottle.cleanCache" {
                return try cleanShaderCaches(container: workspace.resolve(params))
            }
            return try bottleTool(params: params, workspace: workspace)
        case "programs":
            guard method == "programs.run" else {
                throw BridgeFailure("method_unavailable", "Program method is unavailable")
            }
            return try runProgram(params: params, workspace: workspace)
        case "winetricks":
            return try await winetricks.call(method, params: params, workspace: workspace)
        case "setup":
            if let wineSetup, wineSetup.externalRuntime == nil || bottleCreation == nil || method != "setup.status" {
                if method == "setup.status" {
                    return wineSetup.status(anyEngineAvailable: engineStore?.anyEngineAvailable() ?? false)
                }
                return try wineSetup.call(method, params: params) { [weak self] in
                    guard let self else { return }
                    let host = self.engineStore?.managedEngine().makeHost(environment: self.engineStore?.environment ?? ProcessInfo.processInfo.environment) ?? self.wineHost
                    guard let host, host.canExecute else { return }
                    for container in try workspace.containers() {
                        if self.engineStore != nil, !self.containerUsesManagedEngine(container) {
                            continue
                        }
                        if await host.serverRunning(prefix: container) {
                            throw BridgeFailure(
                                "runtime_busy",
                                "Close running Wine applications before updating the runtime"
                            )
                        }
                    }
                }
            }
            guard method == "setup.status", let bottleCreation else {
                throw BridgeFailure("method_unavailable", "Setup method is unavailable")
            }
            let anyEngine = engineStore?.anyEngineAvailable() ?? false
            guard let host = bottleCreation.host, let runtimeURL = bottleCreation.runtimeURL else {
                return .object([
                    "installed": .bool(false),
                    "managedInstalled": .bool(false),
                    "anyEngineAvailable": .bool(anyEngine),
                    "version": .null,
                    "path": .string(wineSetup?.root.appendingPathComponent("current").path ?? LinuxWineSetupService.defaultRoot().appendingPathComponent("current").path),
                    "canExecute": .bool(false),
                    "translation": .null,
                    "rosettaInstalled": .bool(false),
                    "appleSilicon": .bool(false)
                ])
            }
            let version = await bottleCreation.wineVersion()
            let detail: String? = switch (version, host.translation) {
            case let (version?, .native): version
            case let (version?, .binfmt(name)): "\(version) (\(host.architecture) via \(name))"
            case let (version?, .emulator(url)): "\(version) (\(host.architecture) via \(url.lastPathComponent))"
            case (_, .unavailable): "无法执行（需 \(host.architecture) 转译器）"
            case (nil, _): nil
            }
            return .object([
                "installed": .bool(true),
                "managedInstalled": .bool(true),
                "anyEngineAvailable": .bool(true),
                "version": detail.map(JSONValue.string) ?? .null,
                "path": .string(runtimeURL.path),
                "canExecute": .bool(host.canExecute),
                "translation": .string(host.translationDescription),
                "runtimeArchitecture": .string(host.architecture),
                "rosettaInstalled": .bool(false),
                "appleSilicon": .bool(false)
            ])
        case "runtime":
            guard let runtimeService else {
                throw BridgeFailure("method_unavailable", "Runtime method is unavailable")
            }
            return try await runtimeService.call(method, params: params, workspace: workspace)
        default:
            throw BridgeFailure("method_unavailable", "Native method is unavailable")
        }
    }

    /// Mirrors the macOS adapter's `Wine.killBottle`: deleting (or detaching)
    /// a container must not leave its Wine processes running against a prefix
    /// that no longer exists.
    public func prepareContainerRemoval(_ container: URL) async throws {
        guard let host = resolveOptionalHost(for: container), host.canExecute else { return }
        guard try await host.probeServer(prefix: container) else { return }
        try await LinuxWineProcessHost(host: host).terminateAllProcesses(in: container)
    }

    public func shutdown(applyExitPolicy: Bool) async {
        runtimeService?.stopTracking()
    }

    public func prepareShutdown(applyExitPolicy: Bool) async throws {
        guard applyExitPolicy, hasWineCapability else { return }
        let globalKill = try preferences?.call("preferences.read", params: [:])
            .object?["killOnTerminate"]?.bool ?? true
        let containers = try shutdownContainers?() ?? Array(runtimeService?.containerURLs ?? [])
        for container in Set(containers).sorted(by: { $0.path < $1.path }) {
            let metadata = try ProgramSettingsService.load(container.appendingPathComponent("Metadata.plist"))
            let cleanup = metadata["cleanupConfig"] as? [String: Any] ?? [:]
            let policy = cleanup["killOnQuit"] as? String ?? "inherit"
            guard policy == "always" || (policy == "inherit" && globalKill) else { continue }
            guard let host = resolveOptionalHost(for: container), host.canExecute else { continue }
            if try await host.probeServer(prefix: container) {
                try await LinuxWineProcessHost(host: host).terminateAllProcesses(in: container)
            }
        }
        await finalObservation?()
    }

    // MARK: - Bottle tools & ad-hoc runs

    private func bottleTool(params: [String: JSONValue], workspace: ApplicationWorkspace) throws -> JSONValue {
        let container = try workspace.resolve(params)
        let tool = try params.text("tool")
        switch tool {
        case "terminal":
            let wineEnv = resolveOptionalHost(for: container)?.environment(prefix: container) ?? [:]
            return try terminals.open(
                container: container,
                preferred: terminalPreference(),
                wineEnvironment: wineEnv
            )
        case "winecfg", "regedit", "control", "taskmgr":
            let resolved = try resolveContainerHost(for: container, missingCapability: false)
            let lease = try resolved.engine.map { try engineStore!.acquireSharedLease(for: $0.id) }
            let host = resolved.host
            let process = host.process(
                host.loader,
                arguments: [tool],
                prefix: container,
                environment: ["WINEDEBUG": "fixme-all"]
            )
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in lease?.release() }
            do {
                try process.run()
            } catch {
                lease?.release()
                throw BridgeFailure("host_failed", "Could not start \(tool): \(error.localizedDescription)")
            }
            return .object(["accepted": .bool(true), "tool": .string(tool)])
        default:
            throw BridgeFailure("invalid_params", "Unknown Wine tool: \(tool)")
        }
    }

    /// Wipes shader caches scoped to the container: every `*.dxvk-cache`
    /// file inside the prefix. Mesa's own shader cache is per-user global
    /// state shared by every process on the host, so it is deliberately not
    /// touched — deleting it would evict the shader cache of unrelated games
    /// running outside this container.
    private func cleanShaderCaches(container: URL) throws -> JSONValue {
        let manager = FileManager.default
        var removed = 0
        let files = manager.enumerator(
            at: container,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )?.allObjects.compactMap { $0 as? URL } ?? []
        for file in files where file.lastPathComponent.hasSuffix(".dxvk-cache") {
            try manager.removeItem(at: file)
            removed += 1
        }
        return .object([
            "removed": .bool(removed > 0),
            "removedCount": .integer(Int64(removed))
        ])
    }

    private func runProgram(params: [String: JSONValue], workspace: ApplicationWorkspace) throws -> JSONValue {
        guard let jobs else {
            throw BridgeFailure("method_unavailable", "Program execution requires the Wine runtime")
        }
        let container = try workspace.resolve(params)
        let resolved = try resolveContainerHost(for: container, missingCapability: false)
        let host = resolved.host
        let executable = try params.path("executable")
        let runnable: Set = ["exe", "msi", "bat", "cmd", "com", "url"]
        guard runnable.contains(executable.pathExtension.lowercased()) else {
            throw BridgeFailure("invalid_params", "Expected a runnable Windows file")
        }
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw BridgeFailure("file_missing", "Selected file is unavailable")
        }
        let lease = try resolved.engine.map { try engineStore!.acquireSharedLease(for: $0.id) }
        do {
            return try jobs.start(name: "programs.run") { _ in
                defer { lease?.release() }
                let configuration = try await LinuxLaunchConfiguration.load(
                    container: container,
                    executable: executable,
                    engine: resolved.engine,
                    featureOverrides: resolved.overrides
                )
                try await LinuxWineConfiguration.prepare(container: container, host: host)
                let history = try LinuxProgramRunHistory.begin(
                    container: container,
                    executable: executable,
                    logs: HostPaths.logs()
                )
                let result: LinuxWineHost.Output
                do {
                    result = try await host.run(
                        host.loader,
                        arguments: configuration.wineArguments(for: executable),
                        prefix: container,
                        environment: configuration.environment,
                        workingDirectory: executable.deletingLastPathComponent(),
                        outputLimit: 32 * 1_024,
                        logFile: history.log
                    )
                } catch {
                    try history.finish(exitCode: -1)
                    throw error
                }
                try history.finish(exitCode: result.status)
                try Task.checkCancellation()
                guard result.status == 0 else {
                    let tail = result.output.split(whereSeparator: \.isNewline).suffix(4).joined(separator: " | ")
                    let detail = tail.isEmpty ? "" : ": \(tail)"
                    throw BridgeFailure("launch_failed", "Wine exited with status \(result.status)\(detail)")
                }
                return .object(["path": .string(executable.path)])
            }
        } catch {
            lease?.release()
            throw error
        }
    }

    private func resolveOptionalHost(for container: URL) -> LinuxWineHost? {
        if let engineStore {
            return try? engineStore.resolveHost(for: container).host
        }
        return wineHost
    }

    private func resolveContainerHost(
        for container: URL,
        missingCapability: Bool
    ) throws -> (engine: LinuxWineEngine?, host: LinuxWineHost, overrides: [String: String]) {
        if let engineStore {
            do {
                let resolved = try engineStore.resolveHost(for: container)
                return (resolved.engine, resolved.host, resolved.overrides)
            } catch let error as LinuxWineEngineStoreError {
                throw BridgeFailure("runtime_unavailable", error.localizedDescription)
            }
        }
        guard let host = wineHost else {
            throw BridgeFailure(
                missingCapability ? "capability_unavailable" : "method_unavailable",
                missingCapability ? "This setting requires the Wine host adapter" : "This tool requires the Wine host adapter"
            )
        }
        guard host.canExecute else {
            throw BridgeFailure("runtime_unavailable", host.unavailableReason ?? "The Wine runtime cannot run")
        }
        return (nil, host, [:])
    }

    private func systemCall(
        _ method: String,
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) throws -> JSONValue {
        switch method {
        case "system.terminals": return try terminals.describe(preferred: terminalPreference())
        case "system.resources":
            var tools = ["cabextract", "winetricks", "wine", "wineserver", "xdg-open"].map { name in
                (name, locateTool(name).map { JSONValue.string($0.path) } ?? .null)
            }
            tools.append(("whisky-file-picker", picker.executable.map { .string($0.path) } ?? .null))
            return .object([
                "kitBundle": .null,
                "tools": .object(Dictionary(uniqueKeysWithValues: tools))
            ])
        case "system.reveal", "system.open":
            let container = try workspace.resolve(params)
            let path = params["path"] == nil ? container : try params.path("path")
            guard FileManager.default.fileExists(atPath: path.path) else {
                throw BridgeFailure("file_missing", "Selected file is unavailable")
            }
            if method == "system.reveal" {
                var isDirectory: ObjCBool = false
                _ = FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory)
                return isDirectory.boolValue
                    ? try openTarget(path)
                    : try openTarget(path.deletingLastPathComponent())
            } else {
                return try openTarget(path)
            }
        default:
            throw BridgeFailure("method_unavailable", "Native method is unavailable")
        }
    }

    private func terminalPreference() throws -> String {
        try preferences?.call("preferences.read", params: [:]).object?["preferredLinuxTerminal"]?.string ?? "auto"
    }

    private func openTarget(_ url: URL) throws -> JSONValue {
        do {
            try openFile(url)
            return .object(["accepted": .bool(true)])
        } catch let failure as BridgeFailure {
            throw failure
        } catch {
            throw BridgeFailure("host_failed", error.localizedDescription)
        }
    }

    private func locateTool(_ name: String) -> URL? {
        if let host = wineHost ?? engineStore?.managedEngine().makeHost(environment: engineStore?.environment ?? ProcessInfo.processInfo.environment) {
            if name == "wine" {
                return host.loader
            }
            if name == "wineserver" {
                return host.wineserver
            }
        }
        if name == "winetricks", let script = winetricks.winetricksExecutable {
            return script
        }
        for directory in searchPaths {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private nonisolated static func defaultSearchPaths(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        let raw = environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        return raw.split(separator: ":").filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: String($0)) }
    }

    private nonisolated static func xdgOpen(_ url: URL) throws {
        guard let opener = defaultSearchPaths().map({ $0.appendingPathComponent("xdg-open") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
        else {
            throw BridgeFailure("host_failed", "xdg-open is unavailable on this host")
        }
        let process = LinuxManagedProcess()
        process.executableURL = opener
        process.arguments = [url.path]
        process.terminationHandler = { _ in }
        try process.run()
    }
}
