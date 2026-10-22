//
//  FileDiagnosticsService.swift
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
#if os(Linux)
import Glibc
#elseif os(macOS)
import Darwin
#endif

/// Bounded host/container file diagnostics. Collection performs read-only I/O.
@MainActor
final class FileDiagnosticsService {
    static let methods = ["bottle.diagnostics", "bottle.exportDiagnostics", "bottle.checks"]
    private let jobs: BridgeJobStore

    init(jobs: BridgeJobStore) {
        self.jobs = jobs
    }

    func call(_ method: String, params: [String: JSONValue], workspace: ApplicationWorkspace) throws -> JSONValue {
        _ = try workspace.resolve(params)
        try ContainerJournal.requireClear(workspace.registry)
        let destination = method == "bottle.exportDiagnostics" ? try params.path("destination") : nil
        return try jobs.start(name: "diagnostics." + (method.split(separator: ".").last ?? "report")) { _ in
            try ContainerJournal.requireClear(workspace.registry)
            let container = try workspace.resolve(params)
            let snapshot = try FileDiagnosticsSnapshot(container: container, registry: workspace.registry)
            try Task.checkCancellation()
            if let destination {
                try DiagnosticReportWriter.write(
                    snapshot.report,
                    to: destination,
                    container: container,
                    registry: workspace.registry
                )
                return .object(["path": .string(destination.standardizedFileURL.path)])
            }
            if method == "bottle.checks" {
                return .object(["checks": .array(snapshot.checks)])
            }
            return .object(["report": .string(snapshot.report)])
        }
    }
}

struct FileDiagnosticsSnapshot {
    let report: String
    let checks: [JSONValue]

    init(container: URL, registry: URL) throws {
        try Task.checkCancellation()
        let files = FileManager.default
        let marker = container.appendingPathComponent("Metadata.plist")
        let info = Self.readMetadata(marker)?["info"] as? [String: Any]
        let drive = container.appendingPathComponent("drive_c")
        var directory: ObjCBool = false
        let hasDrive = files.fileExists(atPath: drive.path, isDirectory: &directory) && directory.boolValue
        let storage = try? files.attributesOfFileSystem(forPath: container.path)
        let free = (storage?[.systemFreeSize] as? NSNumber)?.int64Value
        let writable = files.isWritableFile(atPath: container.path)
        checks = [
            Self.check(
                "host.container_metadata",
                info?["name"] is String,
                "容器元数据可读取",
                "请检查 Metadata.plist 的类型和内容"
            ),
            Self.check("host.drive_c", hasDrive, "容器 drive_c 目录可访问", "请检查容器 drive_c 目录"),
            Self.check("host.container_write", writable, "系统报告容器具有写入权限", "请检查容器文件权限"),
            Self.check(
                "host.storage",
                free.map { $0 >= 1_073_741_824 } ?? false,
                "容器所在文件系统至少有 1 GiB 可用空间",
                "请检查文件系统可用空间"
            )
        ]
        let environment = ProcessInfo.processInfo.environment
        let session = environment["XDG_SESSION_TYPE"] ?? "unspecified"
        let name = info?["name"] as? String ?? "unreadable"
        let pins = (info?["pins"] as? [Any])?.count ?? 0
        let host = FileDiagnosticsHost.summary()
        let results = Self.describe(checks)
        report = """
        Whisky file diagnostics v1
        \(host)
        Processors: \(ProcessInfo.processInfo.processorCount)
        Physical memory bytes: \(ProcessInfo.processInfo.physicalMemory)
        Session: \(session.prefix(128))
        X11 display configured: \(environment["DISPLAY"] != nil)
        Wayland display configured: \(environment["WAYLAND_DISPLAY"] != nil)
        Container: \(container.path)
        Name: \(name.prefix(1_024))
        Registry: \(registry.path)
        Pinned entries: \(pins)
        Available storage bytes: \(free.map(String.init) ?? "unavailable")
        Runtime probes: outside file diagnostics scope

        File checks
        \(results)
        """
    }

    private static func describe(_ checks: [JSONValue]) -> String {
        checks.compactMap { value -> String? in
            guard let check = value.object, let id = check["checkID"]?.string,
                  let outcome = check["outcome"]?.string, let summary = check["summary"]?.string
            else { return nil }
            return "\(id): \(outcome) — \(summary)"
        }.joined(separator: "\n")
    }

    private static func readMetadata(_ url: URL) -> [String: Any]? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: 16 * 1_024 * 1_024 + 1), data.count <= 16 * 1_024 * 1_024 else {
            return nil
        }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private static func check(_ id: String, _ passed: Bool, _ success: String, _ warning: String) -> JSONValue {
        .object([
            "checkID": .string(id),
            "outcome": .string(passed ? "pass" : "warning"),
            "summary": .string(passed ? success : warning),
            "evidence": .object([:])
        ])
    }
}
