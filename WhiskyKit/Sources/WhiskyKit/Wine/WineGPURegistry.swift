//
//  WineGPURegistry.swift
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
import os.log

private let logger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "WineGPURegistry")

/// Marker for GPU registry sync state so we avoid unnecessary registry writes.
struct GPURegistryState: Codable, Equatable {
    var spoofingEnabled: Bool
    var vendor: String
    var version: Int

    init(spoofingEnabled: Bool, vendor: String, version: Int = 1) {
        self.spoofingEnabled = spoofingEnabled
        self.vendor = vendor
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        case spoofingEnabled, vendor, version
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        spoofingEnabled = try values.decode(Bool.self, forKey: .spoofingEnabled)
        vendor = try values.decode(String.self, forKey: .vendor)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 0
    }

    @MainActor
    static func desired(for bottle: Bottle) -> GPURegistryState {
        let enabled = bottle.settings.launcherCompatibilityMode && bottle.settings.gpuSpoofing
        return GPURegistryState(
            spoofingEnabled: enabled,
            vendor: bottle.settings.gpuVendor.rawValue
        )
    }

    static let factoryDefault = GPURegistryState(
        spoofingEnabled: false,
        vendor: GPUVendor.nvidia.rawValue
    )

    static func markerURL(in bottleURL: URL) -> URL {
        bottleURL.appending(path: ".gpu-registry-state.plist")
    }

    static func load(from bottleURL: URL) -> GPURegistryState? {
        guard let data = try? Data(contentsOf: markerURL(in: bottleURL)) else { return nil }
        return try? PropertyListDecoder().decode(GPURegistryState.self, from: data)
    }

    func save(to bottleURL: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(self).write(to: Self.markerURL(in: bottleURL), options: .atomic)
    }
}

public extension Wine {
    /// Synchronizes the PCI IDs consumed by WineD3D before the next process starts.
    @MainActor
    static func syncGPURegistry(bottle: Bottle) async {
        do {
            try await syncGPURegistry(bottle: bottle, importer: { try await importRegistry(document: $0, bottle: $1) })
        } catch {
            logger.error("Failed to sync GPU registry: \(error.localizedDescription)")
        }
    }
}

extension Wine {
    /// Uses the checked `reg import` path; a failed import retains the previous marker for retry.
    @MainActor
    static func syncGPURegistry(bottle: Bottle, importer: RegistryImporter) async throws {
        let desired = GPURegistryState.desired(for: bottle)
        let applied = GPURegistryState.load(from: bottle.url)
        guard desired != applied else { return }
        if applied == nil, !desired.spoofingEnabled {
            try desired.save(to: bottle.url)
            return
        }

        var lines = ["Windows Registry Editor Version 5.00", "", #"[HKEY_CURRENT_USER\Software\Wine\Direct3D]"#]
        if desired.spoofingEnabled {
            let vendor = bottle.settings.gpuVendor
            lines.append(String(format: #""VideoPciVendorID"=dword:%08x"#, vendor.pciVendorIDInt))
            lines.append(String(format: #""VideoPciDeviceID"=dword:%08x"#, vendor.pciDeviceIDInt))
        } else if applied?.spoofingEnabled == true {
            lines.append(#""VideoPciVendorID"=-"#)
            lines.append(#""VideoPciDeviceID"=-"#)
        }
        // Earlier Whisky builds wrote this unsupported value. Remove it while reconciling their markers.
        lines.append(#""VideoDescription"=-"#)
        try await importer(lines.joined(separator: "\r\n") + "\r\n", bottle)
        try desired.save(to: bottle.url)
    }
}
