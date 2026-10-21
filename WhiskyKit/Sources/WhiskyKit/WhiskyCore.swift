//
//  WhiskyCore.swift
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

import WhiskyCore

// Preserve the WhiskyKit API while sharing the same types with other frontends.
public typealias LibraryEntry = WhiskyCore.LibraryEntry
public typealias LibrarySourceID = WhiskyCore.LibrarySourceID
public typealias LibraryCatalogue = WhiskyCore.LibraryCatalogue
public typealias LauncherType = WhiskyCore.LauncherType
public typealias LibraryCoverGrid = WhiskyCore.LibraryCoverGrid
public typealias GameMetadata = WhiskyCore.GameMetadata
public typealias GameMetadataSource = WhiskyCore.GameMetadataSource
public typealias GameMetadataProvider = WhiskyCore.GameMetadataProvider
public typealias GameMetadataSearch = WhiskyCore.GameMetadataSearch
public typealias GameMetadataSearchResult = WhiskyCore.GameMetadataSearchResult
public typealias GameMetadataAutomaticMatchOutcome = WhiskyCore.GameMetadataAutomaticMatchOutcome
public typealias LibrarySort = WhiskyCore.LibrarySort
public typealias LibraryEntryState = WhiskyCore.LibraryEntryState
public typealias LibraryOrdering = WhiskyCore.LibraryOrdering
public typealias LibrarySortableRow = WhiskyCore.LibrarySortableRow
public typealias LibraryLaunchSnapshot = WhiskyCore.LibraryLaunchSnapshot
public typealias SteamLaunchPhase = WhiskyCore.SteamLaunchPhase
public typealias ExecutablePicker = WhiskyCore.ExecutablePicker
public typealias FolderGameLibrary = WhiskyCore.FolderGameLibrary
public typealias LibraryVisibility = WhiskyCore.LibraryVisibility
public typealias FolderGameMatching = WhiskyCore.FolderGameMatching
public typealias LaunchResult = WhiskyCore.LaunchResult
public typealias GameActivityObservation = WhiskyCore.GameActivityObservation
public typealias ClipboardPolicy = WhiskyCore.ClipboardPolicy
public typealias ClipboardCheckResult = WhiskyCore.ClipboardCheckResult
public typealias TerminalLaunchError = WhiskyCore.TerminalLaunchError
public typealias IconPalette = WhiskyCore.IconPalette
public typealias GameActivity = WhiskyCore.GameActivity
public typealias GameActivityOwner = WhiskyCore.GameActivityOwner
public typealias GameActivitySampleToken = WhiskyCore.GameActivitySampleToken
public typealias GameActivityRecordResult = WhiskyCore.GameActivityRecordResult
public typealias GameActivityClock = WhiskyCore.GameActivityClock
