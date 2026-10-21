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
import Darwin
#elseif os(Linux)
import Glibc
#endif
#if os(macOS)
import WhiskyNativeBridge
#endif

@main
struct BridgeHost {
    @MainActor
    static func main() async {
        // Keep inherited process I/O separate from protocol traffic.
        let protocolInput = dup(STDIN_FILENO)
        let protocolOutput = dup(STDOUT_FILENO)
        guard protocolInput >= 0, protocolOutput >= 0 else { exit(1) }
        _ = fcntl(protocolInput, F_SETFD, FD_CLOEXEC)
        _ = fcntl(protocolOutput, F_SETFD, FD_CLOEXEC)
        let nullInput = open("/dev/null", O_RDONLY)
        guard nullInput >= 0, dup2(nullInput, STDIN_FILENO) >= 0,
              dup2(STDERR_FILENO, STDOUT_FILENO) >= 0
        else { exit(1) }
        close(nullInput)
        signal(SIGPIPE, SIG_IGN)
        let wireOutput = FileHandle(fileDescriptor: protocolOutput, closeOnDealloc: true)
        let arguments = CommandLine.arguments
        func argument(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let workspace = ApplicationWorkspace(
            registry: argument("--registry").map { URL(fileURLWithPath: $0) } ?? HostPaths.registry(),
            containers: argument("--container").map { [URL(fileURLWithPath: $0)] } ?? []
        )
        let preferencesDomain = argument("--preferences-domain") ?? "com.franke.Whisky"
        let preferences = PreferencesService(
            defaults: UserDefaults(suiteName: preferencesDomain) ?? .standard,
            defaultBottleDirectory: workspace.registry.deletingLastPathComponent()
                .appendingPathComponent("Bottles")
        )
        let jobs = BridgeJobStore()
        #if os(macOS)
        let service = ApplicationService(
            workspace: workspace,
            native: MacOSApplicationServices(
                wineEnabled: arguments.contains("--enable-wine"), preferencesDomain: preferencesDomain, jobs: jobs
            ),
            preferences: preferences, jobs: jobs
        )
        #else
        let service = ApplicationService(workspace: workspace, preferences: preferences, jobs: jobs)
        #endif

        let input = AsyncThrowingStream<Data, any Error>(bufferingPolicy: .bufferingOldest(64)) { continuation in
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
        func write(_ response: BridgeResponse) throws {
            let data = try JSONEncoder().encode(response)
            guard data.count <= BridgeFramer.maximumFrameBytes else { throw BridgeFailure(
                "response_too_large",
                "Response exceeds frame budget; narrow the query"
            ) }
            try wireOutput.write(contentsOf: data + Data([10]))
        }
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
                do { try write(response) }
                catch let failure as BridgeFailure { try write(BridgeResponse(id: response.id, error: failure)) }
                if shouldStop {
                    break
                }
            }
            await service.shutdown()
        } catch {
            try? write(BridgeResponse(
                id: nil,
                error: error as? BridgeFailure ?? BridgeFailure("transport_failed", error.localizedDescription)
            ))
            await service.shutdown()
            exit(1)
        }
    }
}
