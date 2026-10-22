//
//  Service+Lifecycle.swift
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

extension ApplicationService {
    var portableLifecycleMethods: [String] {
        #if os(Linux)
        ContainerLifecycleService.methods
        #else
        native == nil ? ContainerLifecycleService.methods : []
        #endif
    }

    var portableDiagnosticsMethods: [String] {
        #if os(Linux)
        FileDiagnosticsService.methods
        #else
        native == nil ? FileDiagnosticsService.methods : []
        #endif
    }

    func lifecycleCall(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
        if portableDiagnosticsMethods.contains(method) {
            return try diagnosticsService.call(method, params: params, workspace: workspace)
        }
        if native?.methods.contains(method) == true || !portableLifecycleMethods.contains(method) {
            return try await nativeCall(method, params: params)
        }
        return try await lifecycleService.call(method, params: params, workspace: workspace)
    }

    func acquireWorkspaceLease(for method: String) throws -> Int32? {
        guard !portableLifecycleMethods.isEmpty else { return nil }
        let scope = method.prefix(while: { $0 != "." })
        let sharedScopes: Set<Substring> = [
            "library", "folders", "entry", "configuration", "programs", "environment", "metadata"
        ]
        if sharedScopes.contains(scope) {
            guard !jobs.hasLifecycleOperation, !ContainerJournal.pending(workspace.registry) else {
                throw BridgeFailure(
                    "recovery_pending",
                    "Wait for lifecycle recovery or the current operation",
                    retryable: true
                )
            }
            return try ContainerRegistry.acquireShared(workspace)
        }
        return ["workspace.containers", "workspace.discover"].contains(method)
            ? try ContainerRegistry.acquireShared(workspace) : nil
    }
}
