//
//  UnavailableLibraryRuntimeDriver.swift
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

/// Explicit capabilities let a frontend offer browsing on hosts awaiting a runtime adapter.
@MainActor
public final class UnavailableLibraryRuntimeDriver: LibraryRuntimeDriver {
    public let snapshot = LibraryRuntimeDriverSnapshot()
    public init() {}
    public func events() -> AsyncStream<LibraryRuntimeDriverEvent> {
        AsyncStream { $0.yield(.changed(snapshot))
            $0.finish()
        }
    }

    public func capabilities(for entry: LibraryEntry) -> LibraryRuntimeCapabilities {
        []
    }

    public func retainContainers(_ urls: Set<URL>) {}
    public func configure(entries: [LibraryEntry], containerURL: URL) async {}
    public func launchProgram(
        _ request: LibraryLaunchRequest, onStarted: @escaping @MainActor () -> Void
    ) async -> LaunchResult {
        .launchFailed(programName: request.entry.name, errorDescription: "Runtime unavailable")
    }

    public func programDidStart(_ request: LibraryLaunchRequest) {}
    public func launchSteam(_ entry: LibraryEntry) {}
    public func cancelSteamLaunch(_ entry: LibraryEntry) {}
    public func stop(_ entry: LibraryEntry) async {}
    public func stopTracking() {}
}
