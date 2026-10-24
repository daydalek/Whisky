//
//  DesktopUpdateTests.swift
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
import Testing
@testable import WhiskyApplication
import WhiskyBridgeProtocol

private func desktop(_ launcher: String, arguments: [String] = [], files: Bool = true) -> String {
    LinuxDesktopEntry.contents(
        name: "Whisky",
        launcher: URL(fileURLWithPath: launcher),
        arguments: arguments,
        handlesFiles: files
    )
}

@Test func managedDesktopRefreshPreservesUserFieldsGroupsAndPermissions() throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let target = fixture.root.appendingPathComponent("Whisky.desktop")
    let original = desktop("/old path/Whisky = app").replacingOccurrences(of: "Name=Whisky", with: "Name=Custom 中文")
        .replacingOccurrences(of: "Icon=applications-games", with: "Icon=my-custom-icon")
        + "# retained comment\nX-User-Setting=opaque\nActions=Custom;\n"
        + "[Desktop Action Custom]\nName=Custom action\nExec=/bin/true\n"
    try Data(original.utf8).write(to: target)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
    let next = desktop("/new path/Whisky = app")
    #expect(try LinuxDesktopUpdater.status(next, at: target, arguments: [[]], handlesFiles: true).needsUpdate)
    #expect(try LinuxDesktopUpdater.publish(next, at: target, arguments: [[]], handlesFiles: true))
    let result = try String(contentsOf: target, encoding: .utf8)
    for retained in [
        "Name=Custom 中文",
        "Icon=my-custom-icon",
        "X-User-Setting=opaque",
        "# retained comment",
        "[Desktop Action Custom]\nName=Custom action\nExec=/bin/true"
    ] {
        #expect(result.contains(retained))
    }
    #expect(try DesktopEntryUpdate.Document(Data(result.utf8)).fields["Exec"] ==
        DesktopEntryUpdate.Document(Data(next.utf8)).fields["Exec"])
    #expect(try (FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?
        .intValue == 0o640)
    #expect(try LinuxDesktopUpdater.status(next, at: target, arguments: [[]], handlesFiles: true).installed)
    #expect(try !LinuxDesktopUpdater.publish(next, at: target, arguments: [[]], handlesFiles: true))
}

@Test func customExecAndForeignTargetsRemainIntact() throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let target = fixture.root.appendingPathComponent("Whisky.desktop")
    let contents = desktop("/old/Whisky").replacingOccurrences(of: "Exec=", with: "Exec=/bin/echo ")
    try Data(contents.utf8).write(to: target)
    #expect(throws: (any Error).self) {
        try LinuxDesktopUpdater.publish(desktop("/new/Whisky"), at: target, arguments: [[]], handlesFiles: true)
    }
    #expect(try String(contentsOf: target, encoding: .utf8) == contents)
    let alias = fixture.root.appendingPathComponent("Alias.desktop")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
    #expect(throws: (any Error).self) {
        try LinuxDesktopUpdater.publish(desktop("/new/Whisky"), at: alias, arguments: [[]], handlesFiles: true)
    }
    #expect(try String(contentsOf: target, encoding: .utf8) == contents)
}

@Test(arguments: [0, 1, 2, 3]) func interruptedDesktopUpdateRecoversAtEveryPublicationBoundary(stage: Int) throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let target = fixture.root.appendingPathComponent("Whisky.desktop")
    let original = Data(desktop("/old/Whisky").utf8)
    let next = Data(desktop("/new/Whisky").utf8)
    try original.write(to: target)
    let record = try DesktopUpdateTransaction.prepare(DesktopFileSnapshot.read(target), contents: next, target: target)
    if stage >= 1 {
        #expect(whisky_host_move(target.path, record.previous.path) == 0)
    }
    if stage >= 2 {
        try FileManager.default.linkItem(at: record.next, to: target)
    }
    if stage >= 3 {
        try FileManager.default.removeItem(at: record.previous)
    }
    try DesktopUpdateTransaction.recover(target)
    #expect(try Data(contentsOf: target) == (stage >= 2 ? next : original))
    #expect(!FileManager.default.fileExists(atPath: DesktopUpdateTransaction.location(target).path))
    #expect(!FileManager.default.fileExists(atPath: record.previous.path))
    #expect(!FileManager.default.fileExists(atPath: record.next.path))
}

@Test func entryEditedBeforeRetirementIsRestoredWithItsEditedBytes() throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let target = fixture.root.appendingPathComponent("Whisky.desktop")
    try Data(desktop("/old/Whisky").utf8).write(to: target)
    let record = try DesktopUpdateTransaction.prepare(
        DesktopFileSnapshot.read(target),
        contents: Data(desktop("/new/Whisky").utf8),
        target: target
    )
    let edited = Data("external editor update".utf8)
    try edited.write(to: target, options: .atomic)
    #expect(throws: (any Error).self) { try record.perform() }
    try DesktopUpdateTransaction.recover(target)
    #expect(try Data(contentsOf: target) == edited)
}

@Test func competingPublisherRetainsBothTheNewTargetAndRetiredEntry() throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let target = fixture.root.appendingPathComponent("Whisky.desktop")
    let original = Data(desktop("/old/Whisky").utf8)
    try original.write(to: target)
    let record = try DesktopUpdateTransaction.prepare(
        DesktopFileSnapshot.read(target),
        contents: Data(desktop("/new/Whisky").utf8),
        target: target
    )
    #expect(whisky_host_move(target.path, record.previous.path) == 0)
    let foreign = Data("concurrent publisher".utf8)
    try foreign.write(to: target)
    #expect(throws: (any Error).self) { try DesktopUpdateTransaction.recover(target) }
    #expect(try Data(contentsOf: target) == foreign)
    #expect(try Data(contentsOf: record.previous) == original)
    #expect(FileManager.default.fileExists(atPath: DesktopUpdateTransaction.location(target).path))
    try FileManager.default.removeItem(at: target)
    try DesktopUpdateTransaction.recover(target)
    #expect(try Data(contentsOf: target) == original)
}

@Test @MainActor func legacyProgramShortcutUpgradesToStableIdentityAndRefreshesItsLauncher() async throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let launcher = fixture.root.appendingPathComponent("New frontend")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: launcher)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
    let target = fixture.root.appendingPathComponent("game.desktop")
    let legacy = desktop("/removed/old frontend", arguments: [
        "--open-file",
        fixture.executable.path,
        "--container",
        fixture.source.path
    ], files: false)
        .replacingOccurrences(
            of: "Name=Whisky",
            with: "Name=Custom game"
        )
    try Data(legacy.utf8).write(to: target)
    let service = LinuxDesktopService(environment: [:], searchPaths: [])
    let params = fixture.params.merging([
        "launcher": .string(launcher.path),
        "executable": .string(fixture.executable.path),
        "destination": .string(fixture.root.path)
    ]) { _, value in value }
    let updated = try await service.call("programs.shortcut.create", params: params, workspace: fixture.workspace)
    #expect(updated.object?["updated"] == .bool(true))
    let contents = try String(contentsOf: target, encoding: .utf8)
    #expect(contents.contains("Name=Custom game"))
    #expect(contents.contains("--container-id"))
    #expect(try contents.contains(#require(updated.object?["containerID"]?.string)))
}

@Test func inPlaceEditsAfterPublicationAreRetainedDuringCleanup() throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let target = fixture.root.appendingPathComponent("Whisky.desktop")
    try Data(desktop("/old/Whisky").utf8).write(to: target)
    let record = try DesktopUpdateTransaction.prepare(
        DesktopFileSnapshot.read(target),
        contents: Data(desktop("/new/Whisky").utf8),
        target: target
    )
    #expect(whisky_host_move(target.path, record.previous.path) == 0)
    try FileManager.default.linkItem(at: record.next, to: target)
    let edited = Data("user edit after publication".utf8)
    try edited.write(to: target)
    try DesktopUpdateTransaction.recover(target)
    #expect(try Data(contentsOf: target) == edited)
    #expect(!FileManager.default.fileExists(atPath: DesktopUpdateTransaction.location(target).path))
}

@Test func malformedRecoveryLocationsPreserveTheEntryAndForeignProgram() throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let target = fixture.root.appendingPathComponent("Whisky.desktop")
    let original = Data(desktop("/old/Whisky").utf8)
    try original.write(to: target)
    let record = try DesktopUpdateTransaction.prepare(
        DesktopFileSnapshot.read(target),
        contents: Data(desktop("/new/Whisky").utf8),
        target: target
    )
    let corrupt = DesktopUpdateTransaction(
        version: 1,
        id: record.id,
        target: target,
        previous: fixture.executable,
        next: record.next,
        oldIdentity: record.oldIdentity,
        newIdentity: record.newIdentity,
        oldData: record.oldData,
        newData: record.newData
    )
    try ContainerJournal.publish(
        PropertyListEncoder().encode(corrupt),
        at: DesktopUpdateTransaction.location(target),
        replace: true
    )
    let program = try Data(contentsOf: fixture.executable)
    #expect(throws: (any Error).self) { try DesktopUpdateTransaction.recover(target) }
    #expect(try Data(contentsOf: target) == original)
    #expect(try Data(contentsOf: fixture.executable) == program)
}

@Test func shortcutNameCollisionsPreserveTheOriginalProgramBinding() throws {
    let fixture = try LifecycleFixture()
    defer { fixture.cleanup() }
    let target = fixture.root.appendingPathComponent("game.desktop")
    let id = "4512E41F-4A7F-4220-A731-564B716940CF"
    let nextArgs = ["--open-file", "drive_c/B/game.exe", "--container-id", id]
    for previous in [
        ["--open-file", "drive_c/A/game.exe", "--container-id", id],
        ["--open-file", "drive_c/B/game.exe", "--container-id", "B36B3313-FE22-4B92-A720-31E1C86B5953"]
    ] {
        let original = Data(desktop("/old/frontend", arguments: previous, files: false).utf8)
        try original.write(to: target)
        #expect(throws: (any Error).self) {
            try LinuxDesktopUpdater.publish(
                desktop("/new/frontend", arguments: nextArgs, files: false),
                at: target,
                arguments: [nextArgs],
                handlesFiles: false
            )
        }
        #expect(try Data(contentsOf: target) == original)
    }
}
