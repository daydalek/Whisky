//
//  WinetricksCatalogTests.swift
//  WhiskyKitTests
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

import Testing
@testable import WhiskyKit

@Test func winetricksCatalogParsesCategoriesAndDescriptions() {
    let catalog = WinetricksService.parseCatalog("""
    ===== apps =====
    7zip                     7-Zip 24.09 (Igor Pavlov, 2024) [downloadable]
    utorrent                 µTorrent 2.2.1 (BitTorrent, 2011)
    ===== dlls =====
    vcrun2022                MS Visual C++ 2015-2022 redistributable
    ===== prefix =====
    ignored_verb             This category is not rendered
    """)

    #expect(catalog.map(\.category) == [.apps, .dlls])
    #expect(catalog[0].verbs.map(\.name) == ["7zip", "utorrent"])
    #expect(catalog[0].verbs[0].description == "7-Zip 24.09 (Igor Pavlov, 2024) [downloadable]")
    #expect(catalog[0].verbs[1].description == "µTorrent 2.2.1 (BitTorrent, 2011)")
    #expect(catalog[1].verbs.map(\.name) == ["vcrun2022"])
    #expect(catalog[1].verbs[0].description == "MS Visual C++ 2015-2022 redistributable")
    #expect(catalog[0].id == .apps)
    #expect(catalog[0].verbs[0].id == "7zip")
}

@Test func winetricksCatalogSkipsBlankAndMalformedLines() {
    let contents = [
        "",
        "===== fonts =====",
        "",
        "   cjkfonts          CJK fonts",
        "no_description",
        "===== games ====="
    ].joined(separator: "\n")
    let catalog = WinetricksService.parseCatalog(contents)

    #expect(catalog.map(\.category) == [.fonts, .games])
    #expect(catalog[0].verbs.map(\.name) == ["cjkfonts", "no_description"])
    #expect(catalog[0].verbs[0].description == "CJK fonts")
    #expect(catalog[0].verbs[1].description.isEmpty)
    #expect(catalog[1].verbs.isEmpty)
}

@Test func winetricksCatalogIgnoresVerbsBeforeAnyCategory() {
    let catalog = WinetricksService.parseCatalog("""
    orphan                   Not associated with a category
    ===== settings =====
    sandbar                  Taskbar settings
    """)

    #expect(catalog.map(\.category) == [.settings])
    #expect(catalog[0].verbs.map(\.name) == ["sandbar"])
}
