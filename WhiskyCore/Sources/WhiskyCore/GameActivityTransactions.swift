//
//  GameActivityTransactions.swift
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

public enum GameActivityOwnershipError: Error, Equatable, Sendable {
    case heldByLiveOwner(GameActivityOwner)
}

public enum GameActivityValidationError: Error, Equatable, Sendable {
    case ratingOutOfRange
}

public extension GameActivity {
    mutating func acquireOwnership(
        source: GameActivityOwner.Source,
        ownerID: UUID,
        process: HostProcessIdentity,
        isAlive: (HostProcessIdentity) -> Bool
    ) throws -> GameActivityOwner {
        if let current = owner {
            if current.ownerID == ownerID, current.process == process {
                return current
            }
            if isAlive(current.process), source != .worker || current.source == .worker {
                throw GameActivityOwnershipError.heldByLiveOwner(current)
            }
        }
        let generation = ownershipGeneration + 1
        let acquired = GameActivityOwner(source: source, ownerID: ownerID, process: process, generation: generation)
        ownershipGeneration = generation
        owner = acquired
        return acquired
    }

    @discardableResult
    mutating func releaseOwnership(ownerID: UUID, generation: UInt64) -> Bool {
        guard owner?.ownerID == ownerID, owner?.generation == generation else { return false }
        owner = nil
        return true
    }

    @discardableResult
    mutating func completeSession(at date: Date, ownerID: UUID, generation: UInt64) -> Bool {
        guard releaseOwnership(ownerID: ownerID, generation: generation) else { return false }
        lastSessionEndedAt = max(lastSessionEndedAt ?? date, date)
        lastPlayed = max(lastPlayed ?? date, date)
        return true
    }

    mutating func recordSample(
        seconds: TimeInterval, at date: Date, token: GameActivitySampleToken
    ) -> GameActivityRecordResult {
        guard seconds.isFinite, seconds >= 0 else { return .alreadyApplied }
        guard let owner, owner.ownerID == token.ownerID, owner.generation == token.generation else {
            return .ownershipChanged(currentOwner: owner)
        }
        if let last = lastAppliedSample, last.ownerID == token.ownerID, last.generation == token.generation,
           last.sequence >= token.sequence {
            return .alreadyApplied
        }
        record(seconds, at: date)
        lastAppliedSample = token
        return .applied(playTime: playTime)
    }

    static func validateRating(_ rating: Int?) throws {
        if let rating, !(1 ... 10).contains(rating) {
            throw GameActivityValidationError.ratingOutOfRange
        }
    }

    mutating func setRating(_ rating: Int?) throws {
        try Self.validateRating(rating)
        self.rating = rating
    }

    @discardableResult
    mutating func record(_ seconds: TimeInterval, at date: Date) -> Bool {
        guard seconds.isFinite, seconds >= 0 else { return false }
        playTime += seconds
        lastPlayed = max(lastPlayed ?? date, date)
        return true
    }

    /// Copy personal history while retaining the destination's active observation lease.
    func preservingOwnership(from destination: GameActivity) -> GameActivity {
        var copy = self
        copy.owner = destination.owner
        copy.ownershipGeneration = destination.ownershipGeneration
        copy.lastAppliedSample = destination.lastAppliedSample
        return copy
    }
}
