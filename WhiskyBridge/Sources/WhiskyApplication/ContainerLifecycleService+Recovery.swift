//
//  ContainerLifecycleService+Recovery.swift
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
import WhiskyBridgeProtocol

extension ContainerLifecycleService {
    func recover(workspace: ApplicationWorkspace) throws -> JSONValue {
        guard workspace.explicitContainers.isEmpty, ContainerJournal.pending(workspace.registry) else {
            return .object(["jobID": .null, "recovered": .bool(false)])
        }
        if let id = recoveryJobID {
            let state = (try? jobs.call("jobs.get", params: ["jobID": .string(id)]))?.object?["status"]?.string
            if ["queued", "running", "cancelling"].contains(state) {
                return .object(["jobID": .string(id)])
            }
        }
        let started = try jobs.start(name: "workspace.recover") { progress in
            progress(.object(["stage": .string("recovering")]))
            return try await Self.detached {
                let lease = try ContainerRegistry.acquire(workspace)
                defer { ContainerRegistry.release(lease) }
                try Task.checkCancellation()
                guard ContainerJournal.pending(workspace.registry) else {
                    return .object(["recovered": .bool(false)])
                }
                return try ContainerRecovery.run(workspace)
            }
        }
        recoveryJobID = started.object?["jobID"]?.string
        return started
    }
}
