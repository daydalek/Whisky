//
//  HostServiceAdapterTests.swift
//  WhiskyKitTests
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

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import WhiskyCore
@testable import WhiskyKit

@Suite("Host service adapters")
struct HostServiceAdapterTests {
    @MainActor @Test func terminalHandoffPreservesLiteralPathsThroughTheShell() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("space ' \" \\ $(printf EXPANDED) `printf EXPANDED`.sh")
        try "printf 'literal-path-ok'\n".write(to: path, atomically: true, encoding: .utf8)
        var generated = ""
        let launcher: any TerminalLaunching = MacOSTerminalLauncher(
            terminal: { .terminal },
            executeScript: { generated = $0 }
        )
        try await launcher.openScript(at: path)
        let line = try #require(generated.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("do script \"") })
        let literal = String(line.dropFirst("do script \"".count).dropLast())
        var command = ""
        var escaped = false
        for character in literal {
            if escaped {
                command.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                command.append(character)
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(data: output, encoding: .utf8) == "literal-path-ok")
    }

    @MainActor @Test func terminalExecutorErrorsRemainVisible() async {
        let launcher = MacOSTerminalLauncher(terminal: { .iterm }, executeScript: { _ in
            throw TerminalLaunchError(message: "execution refused")
        })
        await #expect(throws: TerminalLaunchError(message: "execution refused")) {
            try await launcher.openScript(at: URL(fileURLWithPath: "/tmp/owned-script.sh"))
        }
    }

    @MainActor @Test func programClipboardAndFailureInteractionsUseInjectedServices() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = Bottle(bottleUrl: root)
        bottle.settings.clipboardPolicy = .alwaysWarn
        bottle.settings.clipboardThreshold = 1
        let program = Program(url: root.appendingPathComponent("game.exe"), bottle: bottle)
        let clipboard = TestClipboard()
        let interaction = TestInteraction()
        #expect(program.performClipboardCheck(clipboard: clipboard, interaction: interaction)
            == .autoCleared(contentType: "image", sizeBytes: 100))
        #expect(clipboard.cleared)
        #expect(interaction.prompts == 1)
        program.showRunError(message: "error", interaction: interaction)
        #expect(interaction.failure == "game.exe:error")
    }

    @Test func artworkTransportIsBoundedAndRefreshesReplacedSources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cover.png")
        try png(red: 0, green: 1).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: url.path
        )
        let cache = IconCache(cacheDirectory: nil)
        let provider: any ArtworkProviding = cache
        let request = ArtworkRequest(source: .image(url), maxPixelSize: 16)
        let first = try #require(await provider.artwork(for: request))
        let source = try #require(CGImageSourceCreateWithData(first.data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 16 && image.height == 8)
        #expect(first.palette.green > 0.9)
        try png(red: 1, green: 0).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: url.path
        )
        let updated = try #require(await provider.artwork(for: request))
        #expect(updated.palette.red > 0.9)
        #expect(first.data != updated.data)
    }

    private func png(red: CGFloat, green: CGFloat) throws -> Data {
        let context = try #require(CGContext(
            data: nil,
            width: 64,
            height: 32,
            bitsPerComponent: 8,
            bytesPerRow: 64 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ??
                CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: red, green: green, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

@MainActor
private final class TestClipboard: ClipboardAccess {
    var cleared = false
    func snapshot() -> ClipboardSnapshot {
        ClipboardSnapshot(kind: .image, sizeBytes: 100, version: "1")
    }

    func clear(ifMatches snapshot: ClipboardSnapshot) -> Bool {
        cleared = true
        return true
    }
}

@MainActor
private final class TestInteraction: ProgramUserInteraction {
    var launchMode: LibraryLaunchRequest.Mode {
        .standard
    }

    var failure: String?
    var prompts = 0
    func showLaunchFailure(programName: String, message: String) {
        failure = programName + ":" + message
    }

    func decideClipboard(_ snapshot: ClipboardSnapshot) -> ClipboardDecision {
        prompts += 1
        return .clear
    }
}
