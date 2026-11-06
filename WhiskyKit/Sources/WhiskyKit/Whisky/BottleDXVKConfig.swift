//
//  BottleDXVKConfig.swift
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

public enum DXVKHUD: Codable, Equatable, Sendable {
    case full, partial, fps, off
}

public struct BottleDXVKConfig: Codable, Equatable {
    var dxvk: Bool = false
    var dxvkAsync: Bool = true
    var dxvkHud: DXVKHUD = .off

    private enum CodingKeys: String, CodingKey {
        case dxvkAsync, dxvkHud
        case dxvk // Kept for legacy decode migration into graphicsConfig
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.dxvk = try container.decodeIfPresent(Bool.self, forKey: .dxvk) ?? false
        self.dxvkAsync = try container.decodeIfPresent(Bool.self, forKey: .dxvkAsync) ?? true
        self.dxvkHud = try container.decodeIfPresent(DXVKHUD.self, forKey: .dxvkHud) ?? .off
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // dxvk is purged from serialization: authoritative backend is stored in graphicsConfig.backend
        try container.encode(dxvkAsync, forKey: .dxvkAsync)
        try container.encode(dxvkHud, forKey: .dxvkHud)
    }

    public static func == (lhs: BottleDXVKConfig, rhs: BottleDXVKConfig) -> Bool {
        lhs.dxvkAsync == rhs.dxvkAsync && lhs.dxvkHud == rhs.dxvkHud
    }
}
