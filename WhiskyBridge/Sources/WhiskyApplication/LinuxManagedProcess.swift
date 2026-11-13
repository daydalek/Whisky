//
//  LinuxManagedProcess.swift
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

import CHostCommand
import Foundation
#if os(Linux)
import Glibc
#endif

/// Subprocess wrapper that reaps only its direct child PID on Linux.
///
/// `swift-corelibs-foundation`'s `Process` holds a non-`CLOEXEC` monitor socket
/// across `fork`/`exec`, so long-lived Wine helpers (`wineserver`, `services.exe`,
/// `winedevice.exe`) keep `terminationHandler` blocked indefinitely even after
/// short commands such as `reg import` or `tasklist.exe` have exited.
public final class LinuxManagedProcess: @unchecked Sendable {
    public var executableURL: URL?
    public var arguments: [String]?
    public var environment: [String: String]?
    public var currentDirectoryURL: URL?
    public var standardInput: FileHandle?
    public var standardOutput: FileHandle?
    public var standardError: FileHandle?

    #if os(Linux)
    private let lock = NSLock()
    private var _terminationHandler: (@Sendable (LinuxManagedProcess) -> Void)?
    private var _terminationStatus: Int32 = 0
    private var _isRunning = false
    private var _processIdentifier: Int32 = 0
    private var hasStarted = false

    public var terminationHandler: (@Sendable (LinuxManagedProcess) -> Void)? {
        get { lock.withLock { _terminationHandler } }
        set { lock.withLock { _terminationHandler = newValue } }
    }

    public var terminationStatus: Int32 {
        lock.withLock { _terminationStatus }
    }

    public var isRunning: Bool {
        lock.withLock { _isRunning }
    }

    public var processIdentifier: Int32 {
        lock.withLock { _processIdentifier }
    }

    public init() {}

    public func run() throws {
        guard let executableURL else {
            throw POSIXError(.EINVAL)
        }
        let startedAlready = lock.withLock { () -> Bool in
            if hasStarted { return true }
            hasStarted = true
            return false
        }
        guard !startedAlready else {
            throw POSIXError(.EBUSY)
        }

        let argvStrings = [executableURL.path] + (arguments ?? [])
        let envDict = environment ?? ProcessInfo.processInfo.environment
        let envStrings = envDict.map { "\($0.key)=\($0.value)" }
        let workingDirectory = currentDirectoryURL?.path

        let inHandle = standardInput
        let outHandle = standardOutput
        let errHandle = standardError
        let inFD = inHandle?.fileDescriptor ?? -1
        let outFD = outHandle?.fileDescriptor ?? -1
        let errFD = errHandle?.fileDescriptor ?? -1

        var argv = Self.makeCStringArray(argvStrings)
        var envp = Self.makeCStringArray(envStrings)
        defer {
            Self.freeCStringArray(&argv)
            Self.freeCStringArray(&envp)
        }

        var spawnedPID: pid_t = 0
        let spawnError: Int32 = withExtendedLifetime((inHandle, outHandle, errHandle)) {
            executableURL.path.withCString { execPtr in
                if let workingDirectory {
                    return workingDirectory.withCString { dirPtr in
                        argv.withUnsafeMutableBufferPointer { argvBuf in
                            envp.withUnsafeMutableBufferPointer { envpBuf in
                                whisky_linux_spawn(
                                    execPtr,
                                    argvBuf.baseAddress,
                                    envpBuf.baseAddress,
                                    dirPtr,
                                    inFD,
                                    outFD,
                                    errFD,
                                    &spawnedPID
                                )
                            }
                        }
                    }
                } else {
                    return argv.withUnsafeMutableBufferPointer { argvBuf in
                        envp.withUnsafeMutableBufferPointer { envpBuf in
                            whisky_linux_spawn(
                                execPtr,
                                argvBuf.baseAddress,
                                envpBuf.baseAddress,
                                nil,
                                inFD,
                                outFD,
                                errFD,
                                &spawnedPID
                            )
                        }
                    }
                }
            }
        }

        if spawnError != 0 {
            lock.withLock {
                _terminationStatus = -1
                _isRunning = false
                _terminationHandler = nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: spawnError) ?? .EIO)
        }

        lock.withLock {
            _processIdentifier = spawnedPID
            _isRunning = true
        }

        Thread.detachNewThread { [self, spawnedPID] in
            _ = whisky_linux_wait_no_reap(spawnedPID)
            var status: Int32 = 0
            var signalled: Int32 = 0
            let handler: (@Sendable (LinuxManagedProcess) -> Void)? = lock.withLock {
                _isRunning = false
                let reapErr = whisky_linux_reap_nowait(spawnedPID, &status, &signalled)
                if reapErr == 0 {
                    _terminationStatus = signalled != 0 ? (status != 0 ? status : 1) : status
                } else {
                    _terminationStatus = -1
                }
                let callback = _terminationHandler
                _terminationHandler = nil
                return callback
            }
            handler?(self)
        }
    }

    public func terminate() {
        lock.withLock {
            guard _isRunning, _processIdentifier > 0 else { return }
            _ = Glibc.kill(_processIdentifier, SIGTERM)
        }
    }

    private static func makeCStringArray(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        var result: [UnsafeMutablePointer<CChar>?] = []
        result.reserveCapacity(strings.count + 1)
        for string in strings {
            result.append(string.withCString { strdup($0) })
        }
        result.append(nil)
        return result
    }

    private static func freeCStringArray(_ array: inout [UnsafeMutablePointer<CChar>?]) {
        for pointer in array {
            if let pointer {
                free(pointer)
            }
        }
        array.removeAll()
    }
    #else
    private let underlying = Process()
    private let lock = NSLock()
    private var _terminationHandler: (@Sendable (LinuxManagedProcess) -> Void)?

    public var terminationHandler: (@Sendable (LinuxManagedProcess) -> Void)? {
        get { lock.withLock { _terminationHandler } }
        set { lock.withLock { _terminationHandler = newValue } }
    }

    public var terminationStatus: Int32 {
        underlying.terminationStatus
    }

    public var isRunning: Bool {
        underlying.isRunning
    }

    public var processIdentifier: Int32 {
        underlying.processIdentifier
    }

    public init() {}

    public func run() throws {
        underlying.executableURL = executableURL
        underlying.arguments = arguments
        underlying.environment = environment
        underlying.currentDirectoryURL = currentDirectoryURL
        if let standardInput { underlying.standardInput = standardInput }
        if let standardOutput { underlying.standardOutput = standardOutput }
        if let standardError { underlying.standardError = standardError }
        underlying.terminationHandler = { [weak self] _ in
            guard let self else { return }
            let handler = lock.withLock { () -> (@Sendable (LinuxManagedProcess) -> Void)? in
                let callback = _terminationHandler
                _terminationHandler = nil
                return callback
            }
            handler?(self)
        }
        try underlying.run()
    }

    public func terminate() {
        underlying.terminate()
    }
    #endif
}
