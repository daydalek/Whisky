//
//  SharedPreferencesTests.swift
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
import Testing
@testable import WhiskyKit

@Test func explicitFrontendPreferencesUseTheRequestedDataIdentity() {
    let name = "com.whisky.preferences.tests.\(UUID())"
    let defaults = WhiskyPreferences.defaults(for: name)
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(true, forKey: NetworkSettings.offlineModeKey)
    #expect(!NetworkSettings.shouldCheckWineUpdates(defaults: defaults))
    defaults.set(false, forKey: NetworkSettings.offlineModeKey)
    defaults.set(false, forKey: NetworkSettings.wineUpdatesKey)
    #expect(!NetworkSettings.shouldCheckWineUpdates(defaults: defaults))
    #expect(WhiskyPreferences.defaults(for: name).bool(forKey: NetworkSettings.wineUpdatesKey) == false)
    #expect(WhiskyPreferences.defaults(for: nil) === UserDefaults.standard)
}
