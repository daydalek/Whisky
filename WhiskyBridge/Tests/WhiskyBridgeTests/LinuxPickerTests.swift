//
//  LinuxPickerTests.swift
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

import Foundation
import Testing
@testable import WhiskyApplication
import WhiskyBridgeProtocol
#if os(Linux)
import Glibc
#elseif os(macOS)
import Darwin
#endif

private struct PickerFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("linux-picker-\(UUID())")
        .resolvingSymlinksInPath()
    var bin: URL {
        root.appendingPathComponent("bin")
    }

    init() throws {
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("whisky-file-picker")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func picker(status: Int32 = 0, text: String, signalled: Bool = false) -> LinuxFilePicker {
        LinuxFilePicker(searchPaths: [bin], environment: ["DISPLAY": ":fixture"]) { _, _, _, _ in
            HostCommandResult(status: status, output: Data(text.utf8), signalled: signalled)
        }
    }
}

@Test func linuxPickerPreservesLiteralFilenamesAndPurpose() async throws {
    let fixture = try PickerFixture()
    defer { fixture.remove() }
    let file = fixture.root.appendingPathComponent(" a|中文 $HOME 'quoted'\n\u{1F}.png")
    try Data("fixture".utf8).write(to: file)
    let result = try await fixture.picker(text: file.path + "\0").call("system.choosePath", params: [
        "purpose": .string("metadata-cover"), "extensions": .array([.string("png")])
    ])
    #expect(result.object?["path"] == .string(file.path))
    #expect(result.object?["purpose"] == .string("metadata-cover"))
    let multiple = try await fixture.picker(text: fixture.root.path + "\0" + fixture.bin.path + "\0")
        .call("system.chooseFolders", params: [:])
    #expect(multiple.object?["paths"] == .array([.string(fixture.root.path), .string(fixture.bin.path)]))
}

@Test func linuxPickerSaveAddsTheRequestedExtensionAndCancelStaysDistinctFromFailure() async throws {
    let fixture = try PickerFixture()
    defer { fixture.remove() }
    let result = try await fixture.picker(text: fixture.root.appendingPathComponent("Archive").path + "\0")
        .call("system.choosePath", params: ["mode": .string("save"), "extensions": .array([.string("tar")])])
    #expect(result.object?["path"] == .string(fixture.root.appendingPathComponent("Archive.tar").path))
    try Data("existing archive".utf8).write(to: fixture.root.appendingPathComponent("Archive.tar"))
    await #expect(throws: BridgeFailure.self) {
        try await fixture.picker(text: fixture.root.appendingPathComponent("Archive").path + "\0")
            .call("system.choosePath", params: ["mode": .string("save"), "extensions": .array([.string("tar")])])
    }
    let cancel = try await fixture.picker(status: 1, text: "").call("system.choosePath", params: [:])
    #expect(cancel.object?["path"] == .null)
    await #expect(throws: BridgeFailure.self) {
        try await fixture.picker(status: 1, text: "", signalled: true).call("system.choosePath", params: [:])
    }
    await #expect(throws: BridgeFailure.self) {
        try await fixture.picker(status: 5, text: "").call("system.chooseFolder", params: [:])
    }
    await #expect(throws: BridgeFailure.self) {
        try await fixture.picker(text: fixture.root.path + "\0").call("system.choosePath", params: [:])
    }
}

@Test func linuxPickerValidatesFiltersBeforeStartingTheHostProcess() async throws {
    let fixture = try PickerFixture()
    defer { fixture.remove() }
    let picker = LinuxFilePicker(searchPaths: [fixture.bin], environment: ["DISPLAY": ":fixture"]) { _, _, _, _ in
        Issue.record("Invalid picker parameters reached the process runner")
        return HostCommandResult(status: 1, output: Data())
    }
    for params: [String: JSONValue] in [
        ["mode": .string("unknown")], ["path": .string("relative")],
        ["extensions": .array([.string("png --anything")])],
        ["mode": .string("save"), "name": .string("../file")]
    ] {
        await #expect(throws: BridgeFailure.self) { try await picker.call("system.choosePath", params: params) }
    }
}

@Test func hostCommandDrainsLiteralArgumentsAndFinishesWithItsOwnedChild() async throws {
    let literal = String(repeating: "中文 $HOME `literal` 'quotes' |\n", count: 300)
    let result = try await HostCommand.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "printf '%s' \"$1\"", "fixture", literal],
        environment: ProcessInfo.processInfo.environment,
        timeout: 5
    )
    #expect(result.status == 0 && result.output == Data(literal.utf8))
    let clock = ContinuousClock()
    let start = clock.now
    let descendant = try await HostCommand.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "sleep 30 & printf '%s\\n' $!"],
        environment: ProcessInfo.processInfo.environment,
        timeout: 5
    )
    let text = try #require(String(bytes: descendant.output, encoding: .utf8))
    let pid = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    defer { _ = kill(pid, SIGTERM) }
    #expect(start.duration(to: clock.now) < .seconds(5))
}

@Test func hostCommandBoundsOutputTimeoutAndCancellation() async throws {
    await #expect(throws: BridgeFailure.self) {
        try await HostCommand.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "dd if=/dev/zero bs=1024 count=600"],
            environment: ProcessInfo.processInfo.environment,
            timeout: 5
        )
    }
    await #expect(throws: BridgeFailure.self) {
        try await HostCommand.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; exec sleep 30"],
            environment: ProcessInfo.processInfo.environment,
            timeout: 0.1
        )
    }
    let task = Task {
        try await HostCommand.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exec sleep 30"],
            environment: ProcessInfo.processInfo.environment,
            timeout: 30
        )
    }
    try await Task.sleep(for: .milliseconds(50))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}
