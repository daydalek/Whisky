//
//  WhiskyPreferences.swift
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

/// A host opts into the original application's preferences domain at composition time.
/// Native application and test consumers keep their existing standard-domain behavior.
public enum WhiskyPreferences {
    private final class Selection: @unchecked Sendable {
        let lock = NSLock()
        var domain: String?
    }

    private static let selection = Selection()
    public static func configureSharedDomain(_ identifier: String?) {
        selection.lock.lock()
        selection.domain = identifier
        selection.lock.unlock()
    }

    public static var userDefaults: UserDefaults {
        selection.lock.lock()
        let domain = selection.domain
        selection.lock.unlock()
        return defaults(for: domain)
    }

    public static func defaults(for domain: String?) -> UserDefaults {
        domain.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
}
