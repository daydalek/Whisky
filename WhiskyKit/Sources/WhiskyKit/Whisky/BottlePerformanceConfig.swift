//
//  BottlePerformanceConfig.swift
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

public struct BottlePerformanceConfig: Codable, Equatable {
    var shaderCacheEnabled: Bool = true
    var gpuMemoryLimit: Int? // MB, legacy field retained for decoding
    var disableShaderOptimizations: Bool = false // Legacy field retained for decoding
    var vcRedistInstalled: Bool = false // Track if VC++ runtime is installed
    var disableAppNap: Bool = false // Prevent macOS from throttling Wine processes

    private enum CodingKeys: String, CodingKey {
        case shaderCacheEnabled, vcRedistInstalled, disableAppNap
        case gpuMemoryLimit, disableShaderOptimizations // Kept for decoding legacy plists
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.shaderCacheEnabled = try container.decodeIfPresent(Bool.self, forKey: .shaderCacheEnabled) ?? true
        self.gpuMemoryLimit = try container.decodeIfPresent(Int.self, forKey: .gpuMemoryLimit)
        self.disableShaderOptimizations = try container
            .decodeIfPresent(Bool.self, forKey: .disableShaderOptimizations) ?? false
        self.vcRedistInstalled = try container.decodeIfPresent(Bool.self, forKey: .vcRedistInstalled) ?? false
        self.disableAppNap = try container.decodeIfPresent(Bool.self, forKey: .disableAppNap) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(shaderCacheEnabled, forKey: .shaderCacheEnabled)
        try container.encode(vcRedistInstalled, forKey: .vcRedistInstalled)
        try container.encode(disableAppNap, forKey: .disableAppNap)
        // gpuMemoryLimit and disableShaderOptimizations are purged from serialization
    }

    public static func == (lhs: BottlePerformanceConfig, rhs: BottlePerformanceConfig) -> Bool {
        lhs.shaderCacheEnabled == rhs.shaderCacheEnabled &&
        lhs.vcRedistInstalled == rhs.vcRedistInstalled &&
        lhs.disableAppNap == rhs.disableAppNap
    }
}
