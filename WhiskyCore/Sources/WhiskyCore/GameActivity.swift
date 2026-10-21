//
//  GameActivity.swift
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

public struct GameActivityOwner: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case gui
        case worker
        case cli
    }

    public var source: Source
    public var ownerID: UUID
    public var hostPID: Int32
    public var hostProcessBirth: UInt64
    public var generation: UInt64

    public var process: HostProcessIdentity {
        HostProcessIdentity(pid: hostPID, birth: hostProcessBirth)
    }

    public init(
        source: Source,
        ownerID: UUID = UUID(),
        process: HostProcessIdentity,
        generation: UInt64 = 1
    ) {
        self.source = source
        self.ownerID = ownerID
        self.hostPID = process.pid
        self.hostProcessBirth = process.birth
        self.generation = generation
    }
}

public struct GameActivitySampleToken: Codable, Equatable, Sendable {
    public var ownerID: UUID
    public var generation: UInt64
    public var sequence: UInt64

    public init(ownerID: UUID, generation: UInt64, sequence: UInt64) {
        self.ownerID = ownerID
        self.generation = generation
        self.sequence = sequence
    }
}

public enum GameActivityRecordResult: Sendable, Equatable {
    case applied(playTime: TimeInterval)
    case alreadyApplied
    case ownershipChanged(currentOwner: GameActivityOwner?)
}

public struct GameActivity: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var ownershipGeneration: UInt64 = 0
    public var owner: GameActivityOwner?
    public var lastAppliedSample: GameActivitySampleToken?
    public var playTime: TimeInterval = 0
    public var rating: Int?
    public var lastPlayed: Date?
    /// Confirmed session completion. Legacy lastPlayed samples remain readable separately.
    public var lastSessionEndedAt: Date?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case schemaVersion, ownershipGeneration, owner, lastAppliedSample, playTime, rating, lastPlayed
        case lastSessionEndedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        owner = try container.decodeIfPresent(GameActivityOwner.self, forKey: .owner)
        lastAppliedSample = try container.decodeIfPresent(GameActivitySampleToken.self, forKey: .lastAppliedSample)
        ownershipGeneration = try container.decodeIfPresent(UInt64.self, forKey: .ownershipGeneration)
            ?? max(owner?.generation ?? 0, lastAppliedSample?.generation ?? 0)
        playTime = try container.decodeIfPresent(TimeInterval.self, forKey: .playTime) ?? 0
        rating = try container.decodeIfPresent(Int.self, forKey: .rating)
        lastPlayed = try container.decodeIfPresent(Date.self, forKey: .lastPlayed)
        lastSessionEndedAt = try container.decodeIfPresent(Date.self, forKey: .lastSessionEndedAt)
    }
}
