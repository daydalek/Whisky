//
//  MacOSApplicationServices+Programs+Overrides.swift
//  WhiskyNativeBridge
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

import AppKit
import Foundation
import WhiskyBridgeProtocol
import WhiskyCore
import WhiskyKit

extension MacOSApplicationServices {
    static func dllPayload(_ entries: [DLLOverrideEntry]) -> JSONValue {
        .array(entries.map { entry in
            .object([
                "dllName": .string(entry.dllName),
                "mode": .string(entry.mode.rawValue)
            ])
        })
    }

    static func hudRaw(_ hud: DXVKHUD) -> String {
        switch hud {
        case .full: "full"
        case .partial: "partial"
        case .fps: "fps"
        case .off: "off"
        }
    }

    static func syncRaw(_ sync: EnhancedSync) -> String {
        switch sync {
        case .none: "none"
        case .esync: "esync"
        case .msync: "msync"
        }
    }
}
