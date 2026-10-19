//
//  SteamDownloadSnapshotTests.swift
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
import Testing
@testable import WhiskyKit

@Suite("Steam download snapshots")
struct SteamDownloadSnapshotTests {
    @Test func detectsWritesToExistingDeepFilesAcrossLibraries() throws {
        let temp = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let roots = [temp.appending(path: "primary"), temp.appending(path: "secondary")]
        let files = roots.map { $0.appending(path: "steamapps/downloading/123/Game/Content/Paks/assets.pak") }
        for file in files {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data([0]).write(to: file)
        }
        let first = try SteamDownloadSnapshot.capture(libraryRoots: roots)
        #expect(!first.isEmpty)
        #expect(try first == (SteamDownloadSnapshot.capture(libraryRoots: roots)))
        var previous = first
        for file in files {
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(repeating: 1, count: 1_024))
            try handle.close()
            let next = try SteamDownloadSnapshot.capture(libraryRoots: roots)
            #expect(next != previous)
            previous = next
        }
    }

    @Test func detectsSameSizeFileWritesWithChangedModificationTime() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "steamapps/downloading/123/deep/assets.pak")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0]).write(to: file)
        let first = try SteamDownloadSnapshot.capture(libraryRoots: [root])
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: file.path
        )
        #expect(try first != (SteamDownloadSnapshot.capture(libraryRoots: [root])))
    }

    @Test func cancelledScanReportsCancellation() async {
        let scan = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return try SteamDownloadSnapshot.capture(libraryRoots: [])
        }
        scan.cancel()
        await #expect(throws: CancellationError.self) { _ = try await scan.value }
    }
}
