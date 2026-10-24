//
//  LibraryLaunchSnapshot.swift
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

public enum LibraryEntryState: String, Equatable, Sendable {
    case idle, checkingLaunch, preparing, launching, startingSteam, waitingForSteam, running

    public var isPending: Bool {
        switch self {
        case .idle, .running: false
        default: true
        }
    }
}

public enum SteamLaunchPhase: Equatable, Sendable {
    case startingClient, waitingForClient, launching
}

/// Runtime adapters publish facts. Every frontend applies the same precedence.
public struct LibraryLaunchSnapshot: Equatable, Sendable {
    public var runningEntryIDs: Set<String> = []
    public var programPreparing: Set<String> = []
    public var programLaunching: Set<String> = []
    public var steamRunning: [URL: Set<Int>] = [:]
    public var steamLaunching: [URL: Set<Int>] = [:]
    public var steamPhases: [URL: [Int: SteamLaunchPhase]] = [:]
    public var queryFailureBottles: Set<URL> = []

    public init() {}

    public func state(for entry: LibraryEntry) -> LibraryEntryState {
        if runningEntryIDs.contains(entry.id) {
            return .running
        }
        switch entry.launch {
        case .program:
            if programPreparing.contains(entry.id) {
                return .preparing
            }
            if programLaunching.contains(entry.id) {
                return queryFailureBottles.contains(entry.bottleURL) ? .checkingLaunch : .launching
            }
        case let .steam(appID):
            if steamRunning[entry.bottleURL]?.contains(appID) == true {
                return .running
            }
            if steamLaunching[entry.bottleURL]?.contains(appID) == true {
                switch steamPhases[entry.bottleURL]?[appID] {
                case .startingClient: return .startingSteam
                case .waitingForClient: return .waitingForSteam
                default: return queryFailureBottles.contains(entry.bottleURL) ? .checkingLaunch : .launching
                }
            }
        }
        return .idle
    }
}
