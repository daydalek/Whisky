//
//  WineProcessSnapshotPool.swift
//  WhiskyKit
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

/// Shares in-flight work across UI and lifecycle consumers. Each completed observation expires immediately.
actor WineProcessSnapshotPool {
    static let shared = WineProcessSnapshotPool()

    struct Variable: Hashable, Sendable {
        let name: String
        let value: String
    }

    struct Key: Hashable, Sendable {
        let executable: URL
        let environment: [Variable]
        init(executable: URL, environment: [String: String]) {
            self.executable = executable
            self.environment = environment.map { Variable(name: $0.key, value: $0.value) }
                .sorted { $0.name < $1.name }
        }
    }

    private(set) var inFlightWaiters = 0
    private var requests: [Key: Task<[WineProcess], Error>] = [:]

    func processes(
        key: Key,
        query: @escaping @Sendable () async throws -> [WineProcess]
    ) async throws -> [WineProcess] {
        inFlightWaiters += 1
        defer { inFlightWaiters -= 1 }
        if let request = requests[key] {
            return try await request.value
        }
        let request = Task { try await query() }
        requests[key] = request
        defer { requests[key] = nil }
        return try await request.value
    }
}
