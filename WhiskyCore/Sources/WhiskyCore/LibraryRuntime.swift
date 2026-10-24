//
//  LibraryRuntime.swift
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

public struct LibraryLaunchRequest: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case standard, terminal
    }

    public let entry: LibraryEntry
    public let executableURL: URL?
    public let mode: Mode

    public init(entry: LibraryEntry, executableURL: URL? = nil, mode: Mode = .standard) {
        self.entry = entry
        self.executableURL = executableURL
        self.mode = mode
    }
}

public struct LibraryRuntimeCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let launch = Self(rawValue: 1 << 0)
    public static let cancelLaunch = Self(rawValue: 1 << 1)
    public static let stop = Self(rawValue: 1 << 2)
    public static let terminal = Self(rawValue: 1 << 3)
}

/// Each driver replaces its complete snapshot after observing new runtime facts.
public struct LibraryRuntimeDriverSnapshot: Equatable, Sendable {
    /// Increment for each publication so delayed events preserve observation order.
    public var revision: UInt64 = 0
    public var observation = GameActivityObservation()
    public var queryFailures: [URL: String] = [:]
    public var steamPhases: [URL: [Int: SteamLaunchPhase]] = [:]
    public var steamRunning: [URL: Set<Int>] = [:]
    public init() {}
}

public enum LibraryRuntimeDriverEvent: Sendable {
    case changed(LibraryRuntimeDriverSnapshot)
    case failure(String)
}

public struct LibraryRuntimeState: Equatable, Sendable {
    public var launch = LibraryLaunchSnapshot()
    public var observation = GameActivityObservation()
    public var queryFailures: [URL: String] = [:]
    public init() {}
}

public enum LibraryRuntimeFailure: Equatable, Sendable {
    case launchTimedOut(entryID: String, queryError: String?)
    case unavailable(entryID: String)
    case driver(String)
}

public enum LibraryRuntimeEvent: Equatable, Sendable {
    case state(LibraryRuntimeState)
    case launchResult(entryID: String, result: LaunchResult)
    case failure(LibraryRuntimeFailure)
}

/// UI toolkits consume values and async events and supply explicit launch intent.
@MainActor
public protocol LibraryRuntime: AnyObject {
    var state: LibraryRuntimeState { get }
    func events() -> AsyncStream<LibraryRuntimeEvent>
    func capabilities(for entry: LibraryEntry) -> LibraryRuntimeCapabilities
    func retainContainers(_ urls: Set<URL>)
    func configure(entries: [LibraryEntry], containerURL: URL) async
    func launch(_ request: LibraryLaunchRequest)
    func cancelLaunch(for entry: LibraryEntry)
    func stop(_ entry: LibraryEntry) async
    func stopTracking()
}

/// Platform side effects stay behind this interface. The controller owns request lifetimes.
@MainActor
public protocol LibraryRuntimeDriver: AnyObject {
    var snapshot: LibraryRuntimeDriverSnapshot { get }
    func events() -> AsyncStream<LibraryRuntimeDriverEvent>
    func capabilities(for entry: LibraryEntry) -> LibraryRuntimeCapabilities
    func retainContainers(_ urls: Set<URL>)
    func configure(entries: [LibraryEntry], containerURL: URL) async
    func launchProgram(
        _ request: LibraryLaunchRequest, onStarted: @escaping @MainActor () -> Void
    ) async -> LaunchResult
    func programDidStart(_ request: LibraryLaunchRequest)
    func launchSteam(_ entry: LibraryEntry)
    func cancelSteamLaunch(_ entry: LibraryEntry)
    func stop(_ entry: LibraryEntry) async
    func stopTracking()
}
