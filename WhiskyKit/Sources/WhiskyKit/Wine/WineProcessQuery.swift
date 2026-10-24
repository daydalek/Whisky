//
//  WineProcessQuery.swift
//  WhiskyKit
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

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Captures whole UTF-8 output with bounded lifetime. Files avoid inherited-pipe EOF waits.
enum WineProcessQuery {
    struct Result: Sendable {
        let output: String
        let diagnostics: String
        let exitCode: Int32
    }

    enum Failure: LocalizedError {
        case timedOut, excessiveOutput, invalidProcessList
        case commandFailed(Int32, String)

        var errorDescription: String? {
            switch self {
            case .timedOut: "Wine process query timed out"
            case .excessiveOutput: "Wine process query exceeded its output budget"
            case .invalidProcessList: "Wine returned an unreadable process list"
            case let .commandFailed(code, message): "Wine process query failed (\(code)): \(message)"
            }
        }
    }

    static func run(
        executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval = 15
    ) async throws -> Result {
        try Task.checkCancellation()
        let result = try await Task.detached(priority: .utility) {
            try execute(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
        }.value
        try Task.checkCancellation()
        return result
    }

    private static func execute(
        executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval
    ) throws -> Result {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("stdout")
        let errorURL = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let diagnostics = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close()
            try? diagnostics.close()
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = diagnostics
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        guard exited.wait(timeout: .now() + timeout) == .success else {
            if process.isRunning {
                process.terminate()
            }
            if exited.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            throw Failure.timedOut
        }
        for url in [outputURL, errorURL] {
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            guard size <= 4 * 1_024 * 1_024 else { throw Failure.excessiveOutput }
        }
        guard let text = try String(bytes: Data(contentsOf: outputURL), encoding: .utf8) else {
            throw Failure.invalidProcessList
        }
        let diagnosticText = try String(bytes: Data(
            contentsOf: errorURL
        ), encoding: .utf8) ?? "Unrecognized diagnostic encoding"
        return Result(output: text, diagnostics: diagnosticText, exitCode: process.terminationStatus)
    }
}
