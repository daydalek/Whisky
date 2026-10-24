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

    private let runtimeService: RuntimeService?
    private let wineHost: LinuxWineHost?
    private let bottleCreation: LinuxBottleCreationService?
    private let winetricks: LinuxWinetricksService
    private let jobs: BridgeJobStore?
    private let openFile: FileOpener
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
        shutdownContainers: (() throws -> [URL])? = nil,
        finalObservation: (() async -> Void)? = nil,
        host: LinuxWineHost? = nil
    ) {
        runtimeService = runtime
        self.wineSetup = wineSetup
        self.shutdownContainers = shutdownContainers
        self.finalObservation = finalObservation
        let host = host ?? wineRuntimeURL.flatMap { LinuxWineHost(runtimeURL: $0) }
        wineHost = host
        bottleCreation = host.flatMap { LinuxBottleCreationService(host: $0, jobs: jobs) }
        self.jobs = jobs
        self.preferences = preferences
        let paths = searchPaths ?? Self.defaultSearchPaths()
        self.searchPaths = paths
        let bundled = Bundle.main.executableURL.map { [$0.deletingLastPathComponent()] } ?? []
        let wineBin = host.map { [$0.runtimeURL.appendingPathComponent("bin")] } ?? []
        winetricks = LinuxWinetricksService(
            host: host,
            jobs: jobs,
            searchPaths: bundled + wineBin + paths
        )
        terminals = LinuxTerminalService(searchPaths: paths, environment: ProcessInfo.processInfo.environment)
        desktop = LinuxDesktopService(environment: ProcessInfo.processInfo.environment, searchPaths: paths)
        picker = LinuxFilePicker(searchPaths: bundled + paths)
        self.openFile = openFile ?? Self.xdgOpen
    }

    public var capabilities: [String] {
        var values = ["system.files", "system.picker", "system.terminal", "system.desktop", "programs.shortcut"]
        if wineSetup != nil {
            values.append("setup")
        }
        if wineHost != nil {
            values += winetricks.capabilities
            values.append("processes.read")
        }
        if bottleCreation != nil {
            values.append("setup")
            values.append("bottle.tools")
            values.append("wine.configuration")
        }
        if bottleCreation?.canCreate == true {
            values.append("bottle.create")
        }
        if wineHost != nil, jobs != nil {
            values.append("programs.launch")
        }
        if runtimeService != nil {
            values += RuntimeService.capabilities
        }
        return values
    }

    public var methods: [String] {
        var values = ["system.reveal", "system.open", "system.resources", "system.terminals", "bottle.tools"]
            + LinuxFilePicker.methods + LinuxDesktopService.methods
        values += wineSetup?.methods ?? []
        if wineHost != nil {
            values += winetricks.methods
        }
        if bottleCreation != nil {
            values.append("setup.status")
        }
        if bottleCreation?.canCreate == true {
            values.append("bottle.create")
        }
        if wineHost != nil, jobs != nil {
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
        guard let host = wineHost else {
            throw BridgeFailure("capability_unavailable", "This setting requires the Wine host adapter")
        }
        guard host.canExecute else {
            throw BridgeFailure("runtime_unavailable", host.unavailableReason ?? "The Wine runtime cannot run")
        }
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
                return try wineSetup.call(method, params: params) { [weak self] in
                    guard let host = self?.wineHost, host.canExecute else { return }
                    for container in try workspace.containers() where await host.serverRunning(prefix: container) {
                        throw BridgeFailure(
                            "runtime_busy",
                            "Close running Wine applications before updating the runtime"
                        )
                    }
                }
            }
            guard method == "setup.status", let bottleCreation else {
                throw BridgeFailure("method_unavailable", "Setup method is unavailable")
            }
            let host = bottleCreation.host
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
                "version": detail.map(JSONValue.string) ?? .null,
                "path": .string(bottleCreation.runtimeURL.path),
                "canExecute": .bool(host.canExecute),
                "translation": .string(host.translationDescription),
                "rosettaInstalled": .bool(true),
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

    public func shutdown(applyExitPolicy: Bool) async {
        runtimeService?.stopTracking()
    }

    public func prepareShutdown(applyExitPolicy: Bool) async throws {
        guard applyExitPolicy, let host = wineHost else { return }
        let globalKill = try preferences?.call("preferences.read", params: [:])
            .object?["killOnTerminate"]?.bool ?? true
        let containers = try shutdownContainers?() ?? Array(runtimeService?.containerURLs ?? [])
        let processes = LinuxWineProcessHost(host: host)
        for container in Set(containers).sorted(by: { $0.path < $1.path }) {
            let metadata = try ProgramSettingsService.load(container.appendingPathComponent("Metadata.plist"))
            let cleanup = metadata["cleanupConfig"] as? [String: Any] ?? [:]
            let policy = cleanup["killOnQuit"] as? String ?? "inherit"
            guard policy == "always" || (policy == "inherit" && globalKill) else { continue }
            if try await host.probeServer(prefix: container) {
                try await processes.terminateAllProcesses(in: container)
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
            let wineEnv = wineHost.map { $0.environment(prefix: container) } ?? [:]
            return try terminals.open(
                container: container,
                preferred: terminalPreference(),
                wineEnvironment: wineEnv
            )
        case "winecfg", "regedit", "control":
            guard let host = wineHost else {
                throw BridgeFailure("method_unavailable", "This tool requires the Wine host adapter")
            }
            guard host.canExecute else {
                throw BridgeFailure("runtime_unavailable", host.unavailableReason ?? "The Wine runtime cannot run")
            }
            let process = host.process(
                host.loader,
                arguments: [tool],
                prefix: container,
                environment: ["WINEDEBUG": "fixme-all"]
            )
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in }
            do {
                try process.run()
            } catch {
                throw BridgeFailure("host_failed", "Could not start \(tool): \(error.localizedDescription)")
            }
            return .object(["accepted": .bool(true), "tool": .string(tool)])
        default:
            throw BridgeFailure("invalid_params", "Unknown Wine tool: \(tool)")
        }
    }

    private func runProgram(params: [String: JSONValue], workspace: ApplicationWorkspace) throws -> JSONValue {
        guard let host = wineHost, let jobs else {
            throw BridgeFailure("method_unavailable", "Program execution requires the Wine runtime")
        }
        guard host.canExecute else {
            throw BridgeFailure("runtime_unavailable", host.unavailableReason ?? "The Wine runtime cannot run")
        }
        let container = try workspace.resolve(params)
        let executable = try params.path("executable")
        let runnable: Set = ["exe", "msi", "bat", "cmd", "com", "url"]
        guard runnable.contains(executable.pathExtension.lowercased()) else {
            throw BridgeFailure("invalid_params", "Expected a runnable Windows file")
        }
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw BridgeFailure("file_missing", "Selected file is unavailable")
        }
        return try jobs.start(name: "programs.run") { _ in
            let configuration = try await LinuxLaunchConfiguration.load(container: container, executable: executable)
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
        if let host = wineHost {
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
        let process = Process()
        process.executableURL = opener
        process.arguments = [url.path]
        // Let Foundation reap the child process once xdg-open exits.
        process.terminationHandler = { _ in }
        try process.run()
    }
}
