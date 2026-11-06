//
//  BottleMetalConfig.swift
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

public struct BottleMetalConfig: Codable, Equatable {
    var metalHud: Bool = false
    var metalTrace: Bool = false
    var dxrEnabled: Bool = false
    var metalValidation: Bool = false
    var forceGPUFamily: String?
    var sequoiaCompatMode: Bool = true // Enable Sequoia compatibility by default
    var metal4Enabled: Bool = true // Metal 4 command encoding, D3DMetal ignores it on older systems

    private enum CodingKeys: String, CodingKey {
        case metalHud, metalTrace, dxrEnabled, metalValidation
        case forceGPUFamily, sequoiaCompatMode, metal4Enabled
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.metalHud = try container.decodeIfPresent(Bool.self, forKey: .metalHud) ?? false
        self.metalTrace = try container.decodeIfPresent(Bool.self, forKey: .metalTrace) ?? false
        self.dxrEnabled = try container.decodeIfPresent(Bool.self, forKey: .dxrEnabled) ?? false
        self.metalValidation = try container.decodeIfPresent(Bool.self, forKey: .metalValidation) ?? false
        self.forceGPUFamily = try container.decodeIfPresent(String.self, forKey: .forceGPUFamily)
        self.sequoiaCompatMode = try container.decodeIfPresent(Bool.self, forKey: .sequoiaCompatMode) ?? true
        // Defaults to true for bottles written before this key existed, so an
        // upgrade turns it on rather than silently leaving it off.
        self.metal4Enabled = try container.decodeIfPresent(Bool.self, forKey: .metal4Enabled) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(metalHud, forKey: .metalHud)
        try container.encode(metalTrace, forKey: .metalTrace)
        try container.encode(dxrEnabled, forKey: .dxrEnabled)
        try container.encode(metalValidation, forKey: .metalValidation)
        try container.encodeIfPresent(forceGPUFamily, forKey: .forceGPUFamily)
        // sequoiaCompatMode is a legacy placeholder; decode it but do not re-save.
        try container.encode(metal4Enabled, forKey: .metal4Enabled)
    }
}
