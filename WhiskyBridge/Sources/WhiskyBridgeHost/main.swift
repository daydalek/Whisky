//
//  main.swift
//  WhiskyCore
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
#if os(macOS)
import AppKit
import Darwin
#elseif os(Linux)
import Glibc
#endif
#if os(macOS)
import WhiskyNativeBridge
#endif

@main
struct BridgeHost {
    /// The main thread runs a real AppKit event loop (needed so NSOpenPanel can
    /// be activated and confirmed without AppKit ending the process); the bridge
    /// request loop runs as a MainActor task inside that loop.
    static func main() {
        Task { @MainActor in
            await runBridge()
            exit(0)
        }
        #if os(macOS)
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.run()
        }
        #else
        dispatchMain()
        #endif
    }

    @MainActor
    private static func runBridge() async {
        let (protocolInput, protocolOutput) = configureProtocolIO()
        let service = makeService(arguments: CommandLine.arguments)
        let wireOutput = FileHandle(fileDescriptor: protocolOutput, closeOnDealloc: true)
        let input = makeInput(protocolInput: protocolInput)
        do {
            for try await frame in input {
                let response: BridgeResponse
                var shouldStop = false
                do {
                    let request = try JSONDecoder().decode(BridgeRequest.self, from: frame)
                    response = await service.respond(request)
                    shouldStop = request.method == "bridge.shutdown" && response.error == nil
                } catch { response = BridgeResponse(
                    id: nil,
                    error: BridgeFailure("invalid_request", error.localizedDescription)
                ) }
                do { try write(response, to: wireOutput) } catch let failure as BridgeFailure {
                    try write(BridgeResponse(id: response.id, error: failure), to: wireOutput)
                }
                if shouldStop {
                    break
                }
            }
            await service.shutdown()
        } catch {
            try? write(BridgeResponse(
                id: nil,
                error: error as? BridgeFailure ?? BridgeFailure("transport_failed", error.localizedDescription)
            ), to: wireOutput)
            await service.shutdown()
            exit(1)
        }
    }

    /// Keeps inherited process I/O separate from protocol traffic.
    private static func configureProtocolIO() -> (input: Int32, output: Int32) {
        let input = dup(STDIN_FILENO)
        let output = dup(STDOUT_FILENO)
        guard input >= 0, output >= 0 else { exit(1) }
        _ = fcntl(input, F_SETFD, FD_CLOEXEC)
        _ = fcntl(output, F_SETFD, FD_CLOEXEC)
        let nullInput = open("/dev/null", O_RDONLY)
        guard nullInput >= 0, dup2(nullInput, STDIN_FILENO) >= 0,
              dup2(STDERR_FILENO, STDOUT_FILENO) >= 0
        else { exit(1) }
        close(nullInput)
        signal(SIGPIPE, SIG_IGN)
        return (input, output)
    }

    @MainActor
    private static func makeService(arguments: [String]) -> ApplicationService {
        func argument(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let workspace = ApplicationWorkspace(
            registry: argument("--registry").map { URL(fileURLWithPath: $0) } ?? HostPaths.registry(),
            containers: argument("--container").map { [URL(fileURLWithPath: $0)] } ?? []
        )
        #if os(Linux)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
            .flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? home.appendingPathComponent(".local/share")
        let defaultBottleDirectory = dataHome.appendingPathComponent("whisky/Bottles")
        let preferences = PreferencesService(
            fileURL: HostPaths.preferences(), defaultBottleDirectory: defaultBottleDirectory
        )
        #else
        let preferencesDomain = argument("--preferences-domain") ?? "com.franke.Whisky"
        let defaultBottleDirectory = workspace.registry.deletingLastPathComponent()
            .appendingPathComponent("Bottles")
        let preferences = PreferencesService(
            defaults: UserDefaults(suiteName: preferencesDomain) ?? .standard,
            defaultBottleDirectory: defaultBottleDirectory
        )
        #endif
        let jobs = BridgeJobStore()
        #if os(macOS)
        let native = MacOSApplicationServices(
            wineEnabled: arguments.contains("--enable-wine"), preferencesDomain: preferencesDomain, jobs: jobs
        )
        // Runtime reads stay available without --enable-wine; the native service
        // keeps gating Wine host effects.
        return ApplicationService(
            workspace: workspace,
            native: native,
            runtime: native.runtimeService,
            processes: native.processService,
            preferences: preferences, jobs: jobs
        )
        #elseif os(Linux)
        let environment = ProcessInfo.processInfo.environment
        let wineDisabled = ["1", "true"].contains(environment["WHISKY_BRIDGE_NO_WINE"]?.lowercased() ?? "")
        let externalWine = (argument("--wine-runtime") ?? environment["WHISKY_WINE_RUNTIME"])
            .map { URL(fileURLWithPath: $0) }
        let wineSetup = wineDisabled ? nil : LinuxWineSetupService(
            externalRuntime: externalWine, fallbackRuntime: LinuxWineSetupService.bundledRuntime(),
            jobs: jobs, preferences: preferences,
            releasesURL: environment["WHISKY_LINUX_WINE_RELEASES_URL"].flatMap(URL.init(string:))
        )
        let wineRuntimeURL = wineSetup?.runtimeURL
        let wineDriver = wineRuntimeURL.flatMap { LinuxWineRuntimeDriver(runtimeURL: $0) }
        let wineRuntimeService = wineDriver.map { RuntimeService(driver: $0) }
        let wineProcessService = ProcessService(
            host: wineDriver.map { LinuxWineProcessHost(host: $0.host) }
        )
        return ApplicationService(
            workspace: workspace,
            native: LinuxApplicationServices(
                runtime: wineRuntimeService,
                preferences: preferences,
                wineRuntimeURL: wineRuntimeURL,
                jobs: jobs,
                wineSetup: wineSetup,
                shutdownContainers: { try workspace.containers() },
                finalObservation: { await wineDriver?.poll() }
            ),
            runtime: wineRuntimeService,
            processes: wineProcessService,
            preferences: preferences,
            jobs: jobs
        )
        #else
        return ApplicationService(workspace: workspace, preferences: preferences, jobs: jobs)
        #endif
    }

    private static func makeInput(protocolInput: Int32) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream<Data, any Error>(bufferingPolicy: .bufferingOldest(64)) { continuation in
            let task = Task.detached {
                do {
                    var framer = BridgeFramer()
                    var buffer = [UInt8](repeating: 0, count: 4_096)
                    while !Task.isCancelled {
                        let count = read(protocolInput, &buffer, buffer.count)
                        if count == 0 {
                            break
                        }
                        if count < 0 {
                            if errno == EINTR {
                                continue
                            }
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        for frame in try framer.append(Data(buffer.prefix(count))) {
                            if case .dropped = continuation.yield(frame) {
                                throw BridgeFailure(
                                    "overloaded",
                                    "Input queue is full"
                                )
                            }
                        }
                    }
                    try framer.finish()
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func write(_ response: BridgeResponse, to output: FileHandle) throws {
        let data = try JSONEncoder().encode(response)
        guard data.count <= BridgeFramer.maximumFrameBytes else { throw BridgeFailure(
            "response_too_large",
            "Response exceeds frame budget; narrow the query"
        ) }
        try output.write(contentsOf: data + Data([10]))
    }
}
