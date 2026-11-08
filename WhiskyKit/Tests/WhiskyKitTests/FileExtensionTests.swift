//
//  FileExtensionTests.swift
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

import Foundation
@testable import WhiskyKit
import XCTest

// MARK: - FileHandle.extract Tests

final class FileHandleExtractTests: XCTestCase {
    var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory.appending(path: "test_\(UUID().uuidString).bin")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    func testExtractUInt8() throws {
        let data = Data([0x42])
        try data.write(to: tempURL)

        let handle = try FileHandle(forReadingFrom: tempURL)
        defer { try? handle.close() }

        let value = handle.extract(UInt8.self, offset: 0)
        XCTAssertEqual(value, 0x42)
    }

    func testExtractUInt16() throws {
        let data = Data([0x34, 0x12])
        try data.write(to: tempURL)

        let handle = try FileHandle(forReadingFrom: tempURL)
        defer { try? handle.close() }

        let value = handle.extract(UInt16.self, offset: 0)
        XCTAssertEqual(value, 0x1234)
    }

    func testExtractUInt32() throws {
        let data = Data([0x78, 0x56, 0x34, 0x12])
        try data.write(to: tempURL)

        let handle = try FileHandle(forReadingFrom: tempURL)
        defer { try? handle.close() }

        let value = handle.extract(UInt32.self, offset: 0)
        XCTAssertEqual(value, 0x1234_5678)
    }

    func testExtractUInt64() throws {
        let data = Data([0xEF, 0xCD, 0xAB, 0x90, 0x78, 0x56, 0x34, 0x12])
        try data.write(to: tempURL)

        let handle = try FileHandle(forReadingFrom: tempURL)
        defer { try? handle.close() }

        let value = handle.extract(UInt64.self, offset: 0)
        XCTAssertEqual(value, 0x1234_5678_90AB_CDEF)
    }

    func testExtractWithOffset() throws {
        let data = Data([0x00, 0x00, 0x42, 0x00])
        try data.write(to: tempURL)

        let handle = try FileHandle(forReadingFrom: tempURL)
        defer { try? handle.close() }

        let value = handle.extract(UInt8.self, offset: 2)
        XCTAssertEqual(value, 0x42)
    }

    func testExtractMultipleValues() throws {
        let data = Data([
            0x01, 0x00,
            0x02, 0x00,
            0x03, 0x00, 0x00, 0x00
        ])
        try data.write(to: tempURL)

        let handle = try FileHandle(forReadingFrom: tempURL)
        defer { try? handle.close() }

        let value1 = handle.extract(UInt16.self, offset: 0)
        let value2 = handle.extract(UInt16.self, offset: 2)
        let value3 = handle.extract(UInt32.self, offset: 4)

        XCTAssertEqual(value1, 0x0001)
        XCTAssertEqual(value2, 0x0002)
        XCTAssertEqual(value3, 0x0000_0003)
    }

    func testExtractAtExactEndReturnsNil() throws {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        try data.write(to: tempURL)

        let handle = try FileHandle(forReadingFrom: tempURL)
        defer { try? handle.close() }

        let value = handle.extract(UInt8.self, offset: 4)
        XCTAssertNil(value)
    }

    func testExtractFromEmptyFile() throws {
        let data = Data()
        try data.write(to: tempURL)

        let handle = try FileHandle(forReadingFrom: tempURL)
        defer { try? handle.close() }

        let value = handle.extract(UInt8.self, offset: 0)
        XCTAssertNil(value)
    }

    func testExtractAtOffsetBeyondFileSize() throws {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        try data.write(to: tempURL)

        let handle = try FileHandle(forReadingFrom: tempURL)
        defer { try? handle.close() }

        let value = handle.extract(UInt32.self, offset: 100)
        XCTAssertNil(value)
    }

    func testExtractStraddlingEOFReturnsNil() throws {
        let data = Data([0x01, 0x02])
        try data.write(to: tempURL)

        let handle = try FileHandle(forReadingFrom: tempURL)
        defer { try? handle.close() }

        // A read that starts in bounds but ends past EOF returns fewer bytes than
        // the type needs; extract must return nil, not load past the short buffer.
        XCTAssertNil(handle.extract(UInt32.self, offset: 0))
        XCTAssertNil(handle.extract(UInt32.self, offset: 1))
        XCTAssertNil(handle.extract(UInt16.self, offset: 1))
        XCTAssertEqual(handle.extract(UInt16.self, offset: 0), 0x0201)
    }
}

// MARK: - FileHandle.write(line:) Tests

final class FileHandleWriteLineTests: XCTestCase {
    var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory.appending(path: "test_\(UUID().uuidString).txt")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    func testWriteLine() throws {
        FileManager.default.createFile(atPath: tempURL.path(percentEncoded: false), contents: nil)

        let handle = try FileHandle(forWritingTo: tempURL)
        handle.write(line: "Hello, World!")
        try handle.close()

        let content = try String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertEqual(content, "Hello, World!")
    }

    func testWriteMultipleLines() throws {
        FileManager.default.createFile(atPath: tempURL.path(percentEncoded: false), contents: nil)

        let handle = try FileHandle(forWritingTo: tempURL)
        handle.write(line: "Line 1\n")
        handle.write(line: "Line 2\n")
        handle.write(line: "Line 3")
        try handle.close()

        let content = try String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertEqual(content, "Line 1\nLine 2\nLine 3")
    }

    func testWriteEmptyLine() throws {
        FileManager.default.createFile(atPath: tempURL.path(percentEncoded: false), contents: nil)

        let handle = try FileHandle(forWritingTo: tempURL)
        handle.write(line: "")
        try handle.close()

        let content = try String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertEqual(content, "")
    }

    func testWriteUnicodeContent() throws {
        FileManager.default.createFile(atPath: tempURL.path(percentEncoded: false), contents: nil)

        let handle = try FileHandle(forWritingTo: tempURL)
        handle.write(line: "日本語テスト 🎮")
        try handle.close()

        let content = try String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertEqual(content, "日本語テスト 🎮")
    }
}

// MARK: - FileManager.replaceFile Tests

final class FileManagerReplaceFileTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appending(path: "test_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testReplaceFileWithOriginalCopy() throws {
        let originalURL = tempDir.appending(path: "original.txt")
        let replacementURL = tempDir.appending(path: "replacement.txt")

        try Data("original content".utf8).write(to: originalURL)
        try Data("new content".utf8).write(to: replacementURL)

        try FileManager.default.replaceFile(at: originalURL, with: replacementURL, makeOriginalCopy: true)

        let newContent = try String(contentsOf: originalURL, encoding: .utf8)
        XCTAssertEqual(newContent, "new content")

        let copyURL = originalURL.appendingPathExtension("orig")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copyURL.path(percentEncoded: false)))

        let copyContent = try String(contentsOf: copyURL, encoding: .utf8)
        XCTAssertEqual(copyContent, "original content")
    }

    func testReplaceFileWithoutOriginalCopy() throws {
        let originalURL = tempDir.appending(path: "original.txt")
        let replacementURL = tempDir.appending(path: "replacement.txt")

        try Data("original content".utf8).write(to: originalURL)
        try Data("new content".utf8).write(to: replacementURL)

        try FileManager.default.replaceFile(at: originalURL, with: replacementURL, makeOriginalCopy: false)

        let newContent = try String(contentsOf: originalURL, encoding: .utf8)
        XCTAssertEqual(newContent, "new content")

        let copyURL = originalURL.appendingPathExtension("orig")
        XCTAssertFalse(FileManager.default.fileExists(atPath: copyURL.path(percentEncoded: false)))
    }

    func testReplaceFileWhenOriginalDoesNotExist() throws {
        let originalURL = tempDir.appending(path: "nonexistent.txt")
        let replacementURL = tempDir.appending(path: "replacement.txt")

        try Data("new content".utf8).write(to: replacementURL)

        try FileManager.default.replaceFile(at: originalURL, with: replacementURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path(percentEncoded: false)))
    }

    func testReplaceFileRemovesExistingBackup() throws {
        let originalURL = tempDir.appending(path: "original.txt")
        let replacementURL = tempDir.appending(path: "replacement.txt")
        let backupURL = originalURL.appendingPathExtension("orig")

        try Data("original content".utf8).write(to: originalURL)
        try Data("old backup".utf8).write(to: backupURL)
        try Data("new content".utf8).write(to: replacementURL)

        try FileManager.default.replaceFile(at: originalURL, with: replacementURL, makeOriginalCopy: true)

        let backupContent = try String(contentsOf: backupURL, encoding: .utf8)
        XCTAssertEqual(backupContent, "original content")
    }
}

// MARK: - FileManager.replaceDLLs Tests

final class FileManagerReplaceDLLsTests: XCTestCase {
    var tempDir: URL!
    var destinationDir: URL!
    var sourceDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appending(path: "dll_test_\(UUID().uuidString)")
        destinationDir = tempDir.appending(path: "destination")
        sourceDir = tempDir.appending(path: "source")

        try? FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testReplaceDLLsReplacesMatchingFiles() throws {
        let destDLL = destinationDir.appending(path: "test.dll")
        let srcDLL = sourceDir.appending(path: "test.dll")

        try Data("original dll".utf8).write(to: destDLL)
        try Data("new dll".utf8).write(to: srcDLL)

        try FileManager.default.replaceDLLs(in: destinationDir, withContentsIn: sourceDir)

        let content = try String(contentsOf: destDLL, encoding: .utf8)
        XCTAssertEqual(content, "new dll")
    }

    func testReplaceDLLsIgnoresNonDLLFiles() throws {
        let destFile = destinationDir.appending(path: "test.exe")
        let srcFile = sourceDir.appending(path: "test.exe")

        try Data("original exe".utf8).write(to: destFile)
        try Data("new exe".utf8).write(to: srcFile)

        try FileManager.default.replaceDLLs(in: destinationDir, withContentsIn: sourceDir)

        let content = try String(contentsOf: destFile, encoding: .utf8)
        XCTAssertEqual(content, "original exe")
    }

    func testReplaceDLLsReplacesDLLWhenNonDLLPresent() throws {
        // Regression: a non-DLL entry in the source directory must not abort the
        // copy. With the old early-return, the first non-DLL the enumerator
        // yielded skipped every remaining DLL. `enumerator(at:)` order is
        // unspecified, so we interleave several non-DLL files among multiple
        // DLLs and assert that *all* DLLs are replaced regardless of order.
        for name in ["aaa.txt", "mmm.cfg", ".DS_Store", "zzz.log"] {
            try Data("ignore".utf8).write(to: sourceDir.appending(path: name))
        }

        let dllNames = ["d3d9.dll", "d3d11.dll", "dxgi.dll", "d3d10.dll"]
        for name in dllNames {
            try Data("original".utf8).write(to: destinationDir.appending(path: name))
            try Data("replacement".utf8).write(to: sourceDir.appending(path: name))
        }

        try FileManager.default.replaceDLLs(in: destinationDir, withContentsIn: sourceDir)

        for name in dllNames {
            let content = try String(contentsOf: destinationDir.appending(path: name), encoding: .utf8)
            XCTAssertEqual(content, "replacement", "\(name) must be replaced even when non-DLL files are present")
        }
    }

    func testReplaceDLLsWithMakeOriginalCopy() throws {
        let destDLL = destinationDir.appending(path: "test.dll")
        let srcDLL = sourceDir.appending(path: "test.dll")

        try Data("original dll".utf8).write(to: destDLL)
        try Data("new dll".utf8).write(to: srcDLL)

        try FileManager.default.replaceDLLs(in: destinationDir, withContentsIn: sourceDir, makeOriginalCopy: true)

        let backupURL = destDLL.appendingPathExtension("orig")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path(percentEncoded: false)))
    }

    func testReplaceDLLsInstallsMissingShimOriginal() throws {
        let fileManager = FileManager.default
        let payload = sourceDir.appending(path: "payload")
        let prefix = destinationDir.appending(path: "prefix")
        let pairs: [(arch: String, dest: String)] = [("x64", "system32"), ("x32", "syswow64")]

        for (arch, destName) in pairs {
            let src = payload.appending(path: arch)
            let dest = prefix.appending(path: destName)
            try fileManager.createDirectory(at: src, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: dest, withIntermediateDirectories: true)
            try Data("shim-\(arch) d3d11_original".utf8).write(to: src.appending(path: "d3d11.dll"))
            try Data("payload-\(arch)".utf8).write(to: src.appending(path: "d3d11_original.dll"))
            try Data("old-\(arch)".utf8).write(to: dest.appending(path: "d3d11.dll"))

            try fileManager.replaceDLLs(in: dest, withContentsIn: src)

            XCTAssertEqual(
                try String(contentsOf: dest.appending(path: "d3d11.dll"), encoding: .utf8),
                "shim-\(arch) d3d11_original"
            )
            XCTAssertEqual(
                try String(contentsOf: dest.appending(path: "d3d11_original.dll"), encoding: .utf8),
                "payload-\(arch)"
            )
            XCTAssertEqual(
                try String(contentsOf: src.appending(path: "d3d11.dll"), encoding: .utf8),
                "shim-\(arch) d3d11_original"
            )
            XCTAssertEqual(
                try String(contentsOf: src.appending(path: "d3d11_original.dll"), encoding: .utf8),
                "payload-\(arch)"
            )

            try Data("shim2-\(arch) d3d11_original".utf8).write(to: src.appending(path: "d3d11.dll"))
            try Data("payload2-\(arch)".utf8).write(to: src.appending(path: "d3d11_original.dll"))

            try fileManager.replaceDLLs(in: dest, withContentsIn: src)

            XCTAssertEqual(
                try String(contentsOf: dest.appending(path: "d3d11.dll"), encoding: .utf8),
                "shim2-\(arch) d3d11_original"
            )
            XCTAssertEqual(
                try String(contentsOf: dest.appending(path: "d3d11_original.dll"), encoding: .utf8),
                "payload2-\(arch)"
            )
            for name in ["d3d11.dll.orig", "d3d11_original.dll.orig"] {
                XCTAssertFalse(
                    fileManager.fileExists(atPath: dest.appending(path: name).path(percentEncoded: false)),
                    "\(name) must not be created without makeOriginalCopy"
                )
            }
        }
    }

    func testReplaceDLLsPopulatesEmptyDestination() throws {
        try Data("shim d3d11_original".utf8).write(to: sourceDir.appending(path: "d3d11.dll"))
        try Data("payload".utf8).write(to: sourceDir.appending(path: "d3d11_original.dll"))

        try FileManager.default.replaceDLLs(in: destinationDir, withContentsIn: sourceDir)

        XCTAssertEqual(
            try String(contentsOf: destinationDir.appending(path: "d3d11.dll"), encoding: .utf8),
            "shim d3d11_original"
        )
        XCTAssertEqual(try String(
            contentsOf: destinationDir.appending(path: "d3d11_original.dll"),
            encoding: .utf8
        ), "payload")
    }

    func testReplaceDLLsMakeOriginalCopyBacksUpOnlyExisting() throws {
        let destShim = destinationDir.appending(path: "d3d11.dll")
        let destOriginal = destinationDir.appending(path: "d3d11_original.dll")
        try Data("old-shim".utf8).write(to: destShim)
        try Data("new-shim d3d11_original".utf8).write(to: sourceDir.appending(path: "d3d11.dll"))
        try Data("payload".utf8).write(to: sourceDir.appending(path: "d3d11_original.dll"))

        try FileManager.default.replaceDLLs(in: destinationDir, withContentsIn: sourceDir, makeOriginalCopy: true)

        XCTAssertEqual(try String(contentsOf: destShim, encoding: .utf8), "new-shim d3d11_original")
        XCTAssertEqual(
            try String(contentsOf: destShim.appendingPathExtension("orig"), encoding: .utf8),
            "old-shim"
        )
        XCTAssertEqual(try String(contentsOf: destOriginal, encoding: .utf8), "payload")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destOriginal.appendingPathExtension("orig").path(percentEncoded: false)))
    }
}
