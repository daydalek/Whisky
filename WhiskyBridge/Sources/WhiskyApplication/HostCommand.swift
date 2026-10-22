//
//  HostCommand.swift
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

import CHostCommand
import Foundation
import WhiskyBridgeProtocol
#if os(Linux)
import Glibc
#elseif os(macOS)
import Darwin
#endif

struct HostCommandResult: Sendable {
    let status: Int32
    let output: Data
    var signalled = false
}

/// Owns the POSIX child and drains its output independently of descendant pipe lifetimes.
enum HostCommand {
    static func run(
        executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval
    ) async throws -> HostCommandResult {
        let control = Control()
        return try await withTaskCancellationHandler {
            try await Task.detached {
                try execute(
                    executable: executable,
                    arguments: arguments,
                    environment: environment,
                    timeout: timeout,
                    control: control
                )
            }.value
        } onCancel: { control.cancel() }
    }

    private static func execute(
        executable: URL, arguments: [String], environment: [String: String],
        timeout: TimeInterval, control: Control
    ) throws -> HostCommandResult {
        try control.checkCancellation()
        let child = try spawn(executable: executable, arguments: arguments, environment: environment)
        defer { close(child.output) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var status: Int32 = 0
        var signalled: Int32 = 0
        var exited = false
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        do {
            while true {
                try control.checkCancellation()
                if ProcessInfo.processInfo.systemUptime >= deadline {
                    throw BridgeFailure(
                        "host_timeout",
                        "File selection timed out; open the picker again",
                        retryable: true
                    )
                }
                if !exited {
                    exited = try poll(child.pid, status: &status, signalled: &signalled)
                }
                let count = buffer.withUnsafeMutableBytes { read(child.output, $0.baseAddress, $0.count) }
                if count > 0 {
                    guard output.count + count <= 512 * 1_024 else {
                        throw BridgeFailure("output_too_large", "The selection exceeds the response limit")
                    }
                    output.append(contentsOf: buffer.prefix(count))
                    continue
                }
                if count < 0, errno == EINTR {
                    continue
                }
                if count < 0, !isPendingRead(errno) {
                    throw BridgeFailure("host_failed", "Could not read the host command output")
                }
                if exited {
                    break
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return HostCommandResult(status: status, output: output, signalled: signalled != 0)
        } catch {
            if !exited {
                whisky_host_stop(child.pid)
            }
            throw error
        }
    }

    private static func poll(_ pid: pid_t, status: inout Int32, signalled: inout Int32) throws -> Bool {
        let state = whisky_host_poll(pid, &status, &signalled)
        guard state >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: -state) ?? .EIO) }
        return state == 1
    }

    private static func isPendingRead(_ error: Int32) -> Bool {
        error == EAGAIN || error == EWOULDBLOCK
    }

    private static func spawn(
        executable: URL, arguments: [String], environment: [String: String]
    ) throws -> whisky_host_child {
        var child = whisky_host_child()
        let error = try withStrings([executable.path] + arguments) { arguments in
            try withStrings(environment.map { "\($0.key)=\($0.value)" }) { environment in
                whisky_host_spawn(executable.path, arguments, environment, &child)
            }
        }
        guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
        return child
    }

    private static func withStrings<Value>(
        _ strings: [String], body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Value
    ) throws -> Value {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        defer { for pointer in pointers {
            free(pointer)
        } }
        for string in strings {
            guard !string.contains("\0") else { throw BridgeFailure(
                "invalid_params",
                "Host argument contains a null byte"
            ) }
            guard let pointer = strdup(string) else { throw POSIXError(.ENOMEM) }
            pointers.append(pointer)
        }
        pointers.append(nil)
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            guard let address = buffer.baseAddress else { throw POSIXError(.ENOMEM) }
            return try body(address)
        }
    }

    private final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func checkCancellation() throws {
            if lock.withLock({ cancelled }) {
                throw CancellationError()
            }
        }

        func cancel() {
            lock.withLock { cancelled = true }
        }
    }
}
