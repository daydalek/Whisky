//
//  FileDiagnosticsHost.swift
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
#if os(Linux)
import Glibc
#elseif os(macOS)
import Darwin
#endif

enum FileDiagnosticsHost {
    static func summary() -> String {
        var host = utsname()
        guard uname(&host) == 0 else { return "Host information: unavailable" }
        let kernel = "Kernel: \(text(host.sysname)) \(text(host.release))"
        let architecture = "Architecture: \(text(host.machine))"
        #if os(Linux)
        let distribution = distributionName() ?? "unavailable"
        return "Platform: linux\nDistribution: \(distribution)\n\(kernel)\n\(architecture)"
        #else
        return "Platform: macos\n\(kernel)\n\(architecture)"
        #endif
    }

    private static func text(_ value: some Any) -> String {
        var copy = value
        return withUnsafeBytes(of: &copy) {
            String(bytes: $0.prefix(while: { $0 != 0 }), encoding: .utf8) ?? "unavailable"
        }
    }

    private static func distributionName() -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: "/etc/os-release")) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8_192), let value = String(data: data, encoding: .utf8),
              let line = value.split(separator: "\n").first(where: { $0.hasPrefix("PRETTY_NAME=") })
        else { return nil }
        return String(line.dropFirst(12).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).prefix(256))
    }
}
