//
//  LinuxWineConfiguration.swift
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
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Applies Wine registry effects before a configuration is reported as saved or a game starts.
enum LinuxWineConfiguration {
    private static func acquireLock(_ container: URL) throws -> Int32 {
        let lockURL = container.appendingPathComponent(".whisky-linux-registry.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(.EACCES) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw BridgeFailure("busy", "Another Wine configuration change is in progress", retryable: true)
        }
        return descriptor
    }

    static func importRegistry(
        _ lines: [String],
        container: URL,
        host: LinuxWineHost,
        acquire: Bool = true
    ) async throws {
        let descriptor = acquire ? try acquireLock(container) : nil
        defer {
            if let descriptor {
                _ = flock(descriptor, LOCK_UN)
                close(descriptor)
            }
        }
        let name = "whisky-config-\(UUID().uuidString).reg"
        let url = container.appendingPathComponent("drive_c").appendingPathComponent(name)
        let document = (["Windows Registry Editor Version 5.00", ""] + lines).joined(separator: "\r\n") + "\r\n"
        try ("\u{FEFF}" + document).write(to: url, atomically: true, encoding: .utf16LittleEndian)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await host.run(
            host.loader,
            arguments: ["reg", "import", "C:\\\(name)"],
            prefix: container,
            environment: ["WINEDEBUG": "-all"],
            timeout: .seconds(30)
        )
        try LinuxWineProcessHost.check(result, operation: "Apply Wine configuration")
        try Task.checkCancellation()
    }

    static func virtualDesktop(_ values: [String: ConfigurationValue]) throws -> [String] {
        if values["virtualDesktopEnabled"] == .boolean(true) {
            guard let size = ContainerConfiguration.virtualDesktopResolution(from: values) else {
                throw BridgeFailure("capability_unavailable", "Choose a fixed or custom desktop resolution on Linux")
            }
            return [
                #"[HKEY_CURRENT_USER\Software\Wine\Explorer\Desktops]"#,
                "\"Whisky\"=\"\(size)\"",
                #"[HKEY_CURRENT_USER\Software\Wine\Explorer]"#,
                #""Desktop"="Whisky""#
            ]
        }
        return [#"[HKEY_CURRENT_USER\Software\Wine\Explorer]"#, #""Desktop"=-"#]
    }

    static func launchRegistry(_ values: [String: ConfigurationValue], ownsGPU: Bool = false) -> [String] {
        let latency = switch values["audioLatencyPreset"] {
        case .text("lowLatency"): 512
        case .text("stable"): 131_072
        default: 65_536
        }
        var lines = [
            #"[HKEY_CURRENT_USER\Software\Wine\DirectSound]"#,
            "\"HelBuflen\"=\"\(latency)\""
        ]
        if values["launcherCompatibilityMode"] == .boolean(true), values["gpuSpoofing"] == .boolean(true) {
            lines.append(#"[HKEY_CURRENT_USER\Software\Wine\Direct3D]"#)
            let (vendor, device): (UInt32, UInt32) = switch values["gpuVendor"] {
            case .text("AMD"): (0x1002, 0x73FF)
            case .text("Intel"): (0x8086, 0x9BC5)
            default: (0x10DE, 0x2684)
            }
            lines += [
                String(format: "\"VideoPciVendorID\"=dword:%08x", vendor),
                String(format: "\"VideoPciDeviceID\"=dword:%08x", device)
            ]
        } else if ownsGPU {
            lines += [
                #"[HKEY_CURRENT_USER\Software\Wine\Direct3D]"#,
                #""VideoPciVendorID"=-"#,
                #""VideoPciDeviceID"=-"#
            ]
        }
        return lines
    }

    static func prepare(container: URL, host: LinuxWineHost) async throws {
        let file = ConfigurationFile(url: container.appendingPathComponent("Metadata.plist"), locking: HostFileLock())
        let values = try await file.values(for: ContainerConfiguration.fields)
        let descriptor = try acquireLock(container)
        defer { _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        let marker = container.appendingPathComponent(".whisky-linux-launch-registry.json")
        let previousData = try? Data(contentsOf: marker)
        let previous = previousData.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        let lines = launchRegistry(values, ownsGPU: previous.contains { $0.contains("VideoPciVendorID") })
        let encoded = try JSONEncoder().encode(lines)
        guard previousData != encoded else { return }
        try await importRegistry(lines, container: container, host: host, acquire: false)
        try encoded.write(to: marker, options: .atomic)
    }
}
