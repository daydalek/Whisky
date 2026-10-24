//
//  LibraryEntry.swift
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
import WhiskyCore

/// Somewhere library entries come from.
///
/// Deliberately takes a bottle URL and its settings rather than a ``Bottle``,
/// so a source can run off the main actor and be tested without building one.
public protocol LibrarySource: Sendable {
    static var id: LibrarySourceID { get }
    static func items(inBottleAt url: URL, settings: BottleSettings) -> [LibraryEntry]
}

/// The pinned programs of a bottle.
public enum PinnedLibrarySource: LibrarySource {
    public static let id = LibrarySourceID.pinned

    public static func items(inBottleAt url: URL, settings: BottleSettings) -> [LibraryEntry] {
        items(inBottleAt: url, pins: settings.pins)
    }

    public static func items(inBottleAt url: URL, pins: [PinnedProgram]) -> [LibraryEntry] {
        pins.compactMap { pin in
            guard let programURL = pin.url else { return nil }
            return LibraryEntry(
                id: "pinned:\(programURL.path(percentEncoded: false))",
                name: pin.name,
                iconURL: programURL,
                bottleURL: url,
                source: id,
                launch: .program(programURL),
                launcher: LauncherType.detect(from: programURL)
            )
        }
    }
}

public typealias SteamLibrarySource = WhiskyCore.SteamLibrarySource

extension SteamLibrarySource: LibrarySource {
    public static func items(inBottleAt url: URL, settings _: BottleSettings) -> [LibraryEntry] {
        entries(inBottleAt: url)
    }
}

extension LibraryCatalogue {
    /// Registered sources, in the order their entries are produced. Adding a
    /// launcher is this line plus the type.
    public static var sources: [any (LibrarySource & Sendable).Type] {
        [
            PinnedLibrarySource.self,
            SteamLibrarySource.self
        ]
    }

    /// Everything one bottle contributes to the library.
    public static func items(inBottleAt url: URL, settings: BottleSettings) -> [LibraryEntry] {
        merge(sources.map { $0.items(inBottleAt: url, settings: settings) })
    }
}
