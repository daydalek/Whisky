//
//  LinuxWineHost.swift
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
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// One relocatable Linux Wine runtime (`bin/wine`, `bin/wineserver`, `lib/`)
/// and the way this host executes it.
///
/// The packaged runtime is x86_64. On an aarch64 host it only runs through a
/// translator: either a registered binfmt handler (FEX-Emu, Box64, QEMU or
/// Rosetta for Linux), which makes the ELF directly executable, or an explicit
/// emulator command (`WHISKY_WINE_EMULATOR`, or `box64`/`FEXInterpreter` on
/// `PATH`) that wraps the top-level Wine process. Every Wine and wineserver
/// process the helper starts goes through ``process(_:arguments:prefix:environment:)``
/// so launch, prefix creation, tools and process queries agree on that choice.
public struct LinuxWineHost: Sendable {
    public enum Translation: Sendable, Equatable {
        /// The runtime matches the host CPU.
        case native
        /// The kernel runs the foreign ELF through a binfmt_misc handler.
        case binfmt(String)
        /// Each top-level Wine process is started through this emulator.
        case emulator(URL)
        /// The runtime cannot execute on this host.
        case unavailable
    }

    public let runtimeURL: URL
    public let loader: URL
    public let wineserver: URL
    public let library: URL
    public let architecture: String
    public let hostArchitecture: String
    public let translation: Translation
    private let inherited: [String: String]

    public init?(
        runtimeURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let runtimeURL = runtimeURL.resolvingSymlinksInPath()
        let loader = runtimeURL.appendingPathComponent("bin/wine")
        let wineserver = runtimeURL.appendingPathComponent("bin/wineserver")
        guard FileManager.default.isExecutableFile(atPath: loader.path),
              FileManager.default.isExecutableFile(atPath: wineserver.path)
        else { return nil }
        self.runtimeURL = runtimeURL
        self.loader = loader
        self.wineserver = wineserver
        library = runtimeURL.appendingPathComponent("lib")
        inherited = environment
        let header = Self.elfHeader(loader)
        architecture = header.flatMap(Self.elfArchitecture) ?? "unknown"
        hostArchitecture = Self.hostArchitecture()
        translation = Self.translation(
            header: header,
            architecture: architecture,
            host: hostArchitecture,
            environment: environment
        )
    }

    public var canExecute: Bool {
        translation != .unavailable
    }

    /// A short label for diagnostics and `setup.status`.
    public var translationDescription: String {
        switch translation {
        case .native: "native"
        case let .binfmt(name): "binfmt:\(name)"
        case let .emulator(url): "emulator:\(url.lastPathComponent)"
        case .unavailable: "unavailable"
        }
    }

    /// Why the runtime cannot run, when it cannot.
    public var unavailableReason: String? {
        guard translation == .unavailable else { return nil }
        return "The Wine runtime is \(architecture) but this host is \(hostArchitecture). "
            + "Install an \(architecture) translator (FEX-Emu or Box64 with binfmt support), "
            + "or set WHISKY_WINE_EMULATOR to its executable."
    }

    // MARK: - Environment

    /// The inherited environment with the runtime and prefix applied. The
    /// result is the base layer every Wine process starts from.
    public func environment(prefix: URL) -> [String: String] {
        var environment = inherited
        environment["WINEPREFIX"] = prefix.path
        environment["WINESERVER"] = wineserver.path
        environment["WINELOADER"] = loader.path
        // `bin/wine` resolves its modules relative to itself; the bundled
        // FFmpeg libraries need the runtime lib directory as well.
        if let existing = environment["LD_LIBRARY_PATH"], !existing.isEmpty {
            environment["LD_LIBRARY_PATH"] = "\(library.path):\(existing)"
        } else {
            environment["LD_LIBRARY_PATH"] = library.path
        }
        let bin = runtimeURL.appendingPathComponent("bin").path
        let path = environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        environment["PATH"] = "\(bin):\(path)"
        return environment
    }

    /// Keeps Wine on an installed UTF-8 locale.
    ///
    /// Wine derives both the Windows locale and the Unix file-name charset
    /// from `setlocale`. A requested locale that is not installed silently
    /// falls back to `C`, and a legacy charset such as `zh_CN` (GB2312) cannot
    /// encode kana; either way non-ASCII Unix paths (for example a Japanese
    /// game folder) fail to convert. An installed UTF-8 locale, including a
    /// per-program `ja_JP.UTF-8`, is kept as requested. Otherwise the UTF-8
    /// variant of the same language is used when installed, then `C.UTF-8`,
    /// which glibc always provides.
    public static func applyUsableLocale(to environment: inout [String: String]) {
        let requested = ["LC_ALL", "LC_CTYPE", "LANG"]
            .compactMap { environment[$0] }
            .first { !$0.isEmpty }
        if let requested, isUTF8(requested), localeAvailable(requested) {
            return
        }
        let fallback = utf8Variant(of: requested).first(where: localeAvailable) ?? "C.UTF-8"
        if let requested, requested != fallback {
            FileHandle.standardError.write(Data(
                "whisky-bridge: locale \(requested) is not an installed UTF-8 locale; Wine uses \(fallback)\n".utf8
            ))
        }
        environment["LC_ALL"] = fallback
        environment["LANG"] = fallback
    }

    private static func isUTF8(_ locale: String) -> Bool {
        let upper = locale.uppercased()
        return upper.contains(".UTF-8") || upper.contains(".UTF8")
    }

    private static func utf8Variant(of locale: String?) -> [String] {
        guard let locale, !locale.isEmpty, locale != "C", locale != "POSIX" else { return [] }
        let base = locale.split(separator: ".").first.map(String.init) ?? locale
        let language = base.split(separator: "@").first.map(String.init) ?? base
        return ["\(language).UTF-8", "\(language).utf8"]
    }

    public static func localeAvailable(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        #if canImport(Glibc) || canImport(Darwin)
        guard let handle = newlocale(LC_CTYPE_MASK, name, nil) else { return false }
        freelocale(handle)
        return true
        #else
        return true
        #endif
    }

    // MARK: - Processes

    /// A configured, not yet started process for a runtime executable
    /// (`loader` or `wineserver`).
    public func process(
        _ executable: URL,
        arguments: [String],
        prefix: URL,
        environment extra: [String: String] = [:]
    ) -> Process {
        let process = Process()
        if case let .emulator(emulator) = translation {
            process.executableURL = emulator
            process.arguments = [executable.path] + arguments
        } else {
            let launcher = runtimeURL.appendingPathComponent("run")
            process.executableURL = executable == loader && FileManager.default.isExecutableFile(atPath: launcher.path)
                ? launcher : executable
            process.arguments = arguments
        }
        var environment = environment(prefix: prefix)
        for (key, value) in extra {
            environment[key] = value
        }
        // Checked after every layer so a per-program locale is validated too.
        Self.applyUsableLocale(to: &environment)
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        return process
    }

    public struct Output: Sendable {
        public let status: Int32
        public let output: String
        public let timedOut: Bool
    }

    /// Runs a runtime executable to completion, capturing combined output.
    /// The process is terminated when `timeout` elapses or the task is cancelled.
    public func run(
        _ executable: URL,
        arguments: [String],
        prefix: URL,
        environment extra: [String: String] = [:],
        workingDirectory: URL? = nil,
        timeout: Duration? = nil,
        outputLimit: Int = 256 * 1_024
    ) async throws -> Output {
        guard canExecute else {
            throw BridgeFailure("runtime_unavailable", unavailableReason ?? "The Wine runtime cannot run")
        }
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisky-wine-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else {
            throw BridgeFailure("host_failed", "Could not create a Wine output file")
        }
        let log = try FileHandle(forWritingTo: logURL)
        defer {
            try? log.close()
            try? FileManager.default.removeItem(at: logURL)
        }
        let process = process(executable, arguments: arguments, prefix: prefix, environment: extra)
        process.standardOutput = log
        process.standardError = log
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }
        let box = TimeoutFlag()
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: BridgeFailure(
                        "runtime_unavailable",
                        "Could not start Wine: \(error.localizedDescription)"
                    ))
                    return
                }
                if let timeout {
                    let pid = process.processIdentifier
                    Task.detached {
                        try? await Task.sleep(for: timeout)
                        if process.isRunning, process.processIdentifier == pid {
                            box.set()
                            process.terminate()
                        }
                    }
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
        try? log.synchronize()
        let data = (try? Data(contentsOf: logURL)) ?? Data()
        let output = String(decoding: data.suffix(outputLimit), as: UTF8.self)
        return Output(status: status, output: output, timedOut: box.value)
    }

    /// Whether a wineserver is running for `prefix`, without starting one.
    public func serverRunning(prefix: URL) async -> Bool {
        guard canExecute else { return false }
        let result = try? await run(wineserver, arguments: ["-k0"], prefix: prefix, timeout: .seconds(5))
        return result?.status == 0
    }

    // MARK: - Architecture detection

    private static func elfHeader(_ url: URL) -> [UInt8]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64), data.count >= 20,
              data.prefix(4) == Data([0x7F, 0x45, 0x4C, 0x46])
        else { return nil }
        return [UInt8](data)
    }

    private static func elfArchitecture(_ header: [UInt8]) -> String? {
        let machine = UInt16(header[18]) | UInt16(header[19]) << 8
        switch machine {
        case 0x3E: return "x86_64"
        case 0xB7: return "aarch64"
        case 0x03: return "i386"
        default: return nil
        }
    }

    static func hostArchitecture() -> String {
        var name = utsname()
        guard uname(&name) == 0 else { return "unknown" }
        let machine = withUnsafeBytes(of: &name.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine == "arm64" ? "aarch64" : machine
    }

    private static func translation(
        header: [UInt8]?,
        architecture: String,
        host: String,
        environment: [String: String]
    ) -> Translation {
        let paths = (environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin")
            .split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        func locate(_ name: String) -> URL? {
            if name.hasPrefix("/") {
                return FileManager.default.isExecutableFile(atPath: name) ? URL(fileURLWithPath: name) : nil
            }
            return paths.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
                .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }
        // An explicit emulator wins, so a user can choose Box64 over a
        // registered handler (or test translation on a matching host).
        if let requested = environment["WHISKY_WINE_EMULATOR"], !requested.isEmpty {
            if let emulator = locate(requested) {
                return .emulator(emulator)
            }
            FileHandle.standardError.write(Data(
                "whisky-bridge: WHISKY_WINE_EMULATOR=\(requested) is not executable; ignoring it\n".utf8
            ))
        }
        if architecture == host || (architecture == "i386" && host == "x86_64") {
            return .native
        }
        if let header, let handler = binfmtHandler(for: header) {
            return .binfmt(handler)
        }
        if architecture == "x86_64" {
            for candidate in ["FEXInterpreter", "FEXLoader", "box64"] {
                if let emulator = locate(candidate) {
                    return .emulator(emulator)
                }
            }
        }
        return .unavailable
    }

    /// The name of an enabled binfmt_misc entry whose magic matches `header`.
    static func binfmtHandler(
        for header: [UInt8],
        directory: URL = URL(fileURLWithPath: "/proc/sys/fs/binfmt_misc")
    ) -> String? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }
        let preferred = ["rosetta", "FEX-x86_64", "box64", "box86"]
        let ordered = names.filter { $0 != "register" && $0 != "status" }.sorted { lhs, rhs in
            let lRank = preferred.firstIndex(of: lhs) ?? preferred.count
            let rRank = preferred.firstIndex(of: rhs) ?? preferred.count
            return lRank != rRank ? lRank < rRank : lhs < rhs
        }
        for name in ordered {
            guard let text = try? String(
                contentsOf: directory.appendingPathComponent(name),
                encoding: .utf8
            ) else { continue }
            let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            guard lines.first == "enabled" else { continue }
            var offset = 0
            var magic: [UInt8] = []
            var mask: [UInt8] = []
            for line in lines {
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "offset": offset = Int(parts[1]) ?? 0
                case "magic": magic = hexBytes(parts[1])
                case "mask": mask = hexBytes(parts[1])
                default: break
                }
            }
            guard !magic.isEmpty, offset >= 0, offset + magic.count <= header.count else { continue }
            let matches = magic.indices.allSatisfy { index in
                let byteMask = index < mask.count ? mask[index] : 0xFF
                return header[offset + index] & byteMask == magic[index] & byteMask
            }
            if matches {
                return name.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
                    .unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 }
                    .map(String.init).joined()
            }
        }
        return nil
    }

    private static func hexBytes(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = text.startIndex
        while let next = text.index(index, offsetBy: 2, limitedBy: text.endIndex), index < text.endIndex {
            guard let byte = UInt8(text[index ..< next], radix: 16) else { return [] }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}
