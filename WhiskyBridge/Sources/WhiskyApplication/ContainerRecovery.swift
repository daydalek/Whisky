//
//  ContainerRecovery.swift
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
import WhiskyBridgeProtocol

/// Runs while holding the registry lease. Identity mismatches preserve both
/// trees and the journal, allowing a visible recovery error on the next start.
enum ContainerRecovery {
    static func run(_ workspace: ApplicationWorkspace) throws -> JSONValue {
        let registry = try ContainerRegistry.Document(workspace)
        let journal = try ContainerJournal.read(workspace.registry)
        let committed = registry.committedTransaction == journal.id.uuidString
        guard committed || registry.paths.map(\.absoluteString) == journal.originalPaths.map(\.absoluteString) else {
            throw BridgeFailure("recovery_required", "The registry changed after the interrupted operation")
        }
        switch journal.kind {
        case .duplicate, .crossMove: try recoverCopy(journal, committed: committed, registry: workspace.registry)
        case .move: try recoverMove(journal, committed: committed)
        case .remove: try recoverRemoval(journal, committed: committed)
        }
        if committed {
            try ContainerRoutes.apply(journal, registry: workspace.registry)
        }
        try ContainerJournal.clear(workspace.registry)
        return .object([
            "recovered": .bool(true),
            "transactionID": .string(journal.id.uuidString),
            "outcome": .string(committed ? "committed" : "rolled_back")
        ])
    }

    private static func verify(_ expected: DirectoryIdentity?, at url: URL) throws -> Bool {
        guard let actual = try DirectoryIdentity.read(url) else { return false }
        guard actual == expected else {
            throw BridgeFailure("recovery_required", "Directory identity changed; preserve and inspect \(url.path)")
        }
        return true
    }

    private static func recoverCopy(_ journal: ContainerJournal, committed: Bool, registry: URL) throws {
        if committed {
            guard try verify(journal.destinationIdentity, at: journal.destination) else {
                throw BridgeFailure("recovery_required", "The registered destination is unavailable")
            }
            try ContainerLifecycleService.validate(journal.destination, registry: registry)
            if journal.kind == .crossMove,
               try verify(journal.sourceIdentity, at: journal.source) {
                try ContainerLifecycleService.removeOwnedCopy(journal.source)
            }
        } else {
            guard try verify(journal.sourceIdentity, at: journal.source) else {
                throw BridgeFailure("recovery_required", "The original container is unavailable; preserve the copy")
            }
            if try verify(journal.destinationIdentity, at: journal.destination) {
                try ContainerLifecycleService.removeOwnedCopy(journal.destination)
            }
        }
    }

    private static func recoverMove(_ journal: ContainerJournal, committed: Bool) throws {
        if committed {
            guard try verify(journal.sourceIdentity, at: journal.destination) else {
                throw BridgeFailure("recovery_required", "The moved container is unavailable")
            }
            return
        }
        if try verify(journal.sourceIdentity, at: journal.source) {
            // The rename may never have started, or rollback already restored it.
            try journal.undo?.restore(at: journal.source)
            return
        }
        guard try verify(journal.sourceIdentity, at: journal.destination), let undo = journal.undo else {
            throw BridgeFailure("recovery_required", "The interrupted move requires inspection")
        }
        try undo.restore(at: journal.destination)
        let error = whisky_host_move(journal.destination.path, journal.source.path)
        guard error == 0 else { throw BridgeFailure("recovery_required", "Could not restore \(journal.source.path)") }
    }

    private static func recoverRemoval(_ journal: ContainerJournal, committed: Bool) throws {
        if committed {
            if try verify(journal.sourceIdentity, at: journal.destination) {
                try ContainerLifecycleService.removeOwnedCopy(journal.destination)
            }
            return
        }
        if try verify(journal.sourceIdentity, at: journal.source) {
            return
        }
        guard try verify(journal.sourceIdentity, at: journal.destination) else {
            throw BridgeFailure("recovery_required", "The staged container is unavailable")
        }
        let error = whisky_host_move(journal.destination.path, journal.source.path)
        guard error == 0 else { throw BridgeFailure("recovery_required", "Could not restore \(journal.source.path)") }
    }
}
