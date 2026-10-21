//
//  LibraryDiscoveryTests.swift
//  WhiskyCore
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
@testable import WhiskyCore

@Suite("Portable library discovery publication")
struct LibraryDiscoveryTests {
    private let container = URL(fileURLWithPath: "/test-container")

    @Test func matchingConfigurationPublishesDerivedStateAndKeepsCurrentSettings() {
        var scanned = FolderGameLibrary()
        scanned.roots = ["Games"]
        scanned.knownFolders = ["Games/New"]
        scanned.initializedRoots = ["Games"]
        scanned.pendingMetadata = ["Games/New"]
        let discovery = LibraryDiscovery(containerURL: container, entries: [], folders: scanned)
        var current = FolderGameLibrary()
        current.roots = ["Games"]
        current.executables = ["Games/New": "Games/New/game.exe"]
        current.pendingMetadata = ["Games/Existing"]
        let applied = discovery.apply(to: &current)
        #expect(applied)
        #expect(current.knownFolders == scanned.knownFolders)
        #expect(current.initializedRoots == ["Games"])
        #expect(current.executables == ["Games/New": "Games/New/game.exe"])
        #expect(current.pendingMetadata == ["Games/New", "Games/Existing"])
    }

    @Test func changedRootsAssignmentsOrExclusionsRetainCurrentConfiguration() throws {
        var scanned = FolderGameLibrary()
        scanned.roots = ["Games"]
        scanned.knownFolders = ["Games/Old"]
        let discovery = LibraryDiscovery(containerURL: container, entries: [], folders: scanned)
        for change in 0 ..< 3 {
            var current = scanned
            switch change {
            case 0: current.roots = ["Other"]
            case 1: current.assignedFolders = ["Assigned"]
            default: current.excludedFolders = ["Games/Old"]
            }
            current.executables = ["chosen": "chosen.exe"]
            let before = try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? NSDictionary
            #expect(discovery.apply(to: &current) == false)
            let after = try JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? NSDictionary
            #expect(before == after)
        }
    }

    @Test func emptyConfigurationStaysEmptyAndAssignedFoldersCanPublish() {
        let empty = LibraryDiscovery(containerURL: container, entries: [], folders: FolderGameLibrary())
        var current = FolderGameLibrary()
        #expect(empty.apply(to: &current) == false)
        var assigned = FolderGameLibrary()
        assigned.assignedFolders = ["Outside"]
        assigned.knownFolders = ["Outside"]
        current.assignedFolders = assigned.assignedFolders
        let discovery = LibraryDiscovery(containerURL: container, entries: [], folders: assigned)
        let applied = discovery.apply(to: &current)
        #expect(applied)
        #expect(current.knownFolders == ["Outside"])
    }
}
