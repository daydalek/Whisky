//
//  MacOSApplicationServices+EntryMove.swift
//  WhiskyNativeBridge
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
import WhiskyApplication
import WhiskyBridgeProtocol
import WhiskyCore
import WhiskyKit

extension MacOSApplicationServices {
    /// Re-homes one program/folder entry into another bottle. The executable
    /// stays where it is; only settings, pin state, metadata, activity and
    /// visibility follow the association.
    func entryMove(
        _ params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) async throws -> JSONValue {
        let source = try workspace.resolve(params)
        let targetPath = try params.path("targetContainer")
        let target = try workspace.resolve(["container": .string(targetPath.path)])
        guard source != target else {
            throw BridgeFailure("invalid_params", "The source and target containers are the same")
        }
        let entry = try await workspace.entry([
            "container": .string(source.path),
            "entryID": params["entryID"] ?? .null
        ])
        if case .steam = entry.launch {
            throw BridgeFailure("invalid_params", "Steam entries cannot move between containers")
        }
        let visibility = try LibraryVisibility.load(bottleURL: source)
        let service = WineLibraryContentService(bottleResolver: { [weak self] url in
            self?.bottle(url)
        })
        let moved: LibraryEntry
        do {
            moved = try await service.move(entry, to: target, hidden: !visibility.includes(entry))
        } catch {
            throw BridgeFailure("entry_move_failed", error.localizedDescription)
        }
        bottles[source] = nil
        bottles[target] = nil
        let targetVisibility = try LibraryVisibility.load(bottleURL: target)
        return try .object([
            "sourceContainer": .string(source.path),
            "targetContainer": .string(target.path),
            "entry": .encoded(EntryRecord(moved, visibility: targetVisibility))
        ])
    }
}
