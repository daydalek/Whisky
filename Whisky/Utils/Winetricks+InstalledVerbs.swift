//
//  Winetricks+InstalledVerbs.swift
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

import WhiskyKit

extension Winetricks {
    static func listInstalledVerbs(for bottle: Bottle) async -> Set<String>? {
        await WinetricksService.listInstalledVerbs(for: bottle)
    }

    static func parseWinetricksLog(for bottle: Bottle) async -> Set<String> {
        await WinetricksService.parseWinetricksLog(for: bottle)
    }

    static func loadInstalledVerbs(for bottle: Bottle) async -> (verbs: Set<String>, fromCache: Bool) {
        await WinetricksService.loadInstalledVerbs(for: bottle)
    }
}
