//
//  BottleCreationService.swift
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

import Darwin
import Foundation

public enum BottleCreationServiceError: Error {
    case emptyName
    case runtimeMissing
    case locationUnsuitable(BottleLocationValidation.ValidationResult)
    case directoryCreationFailed
    case metadataCreationFailed
    case registrySaveFailed
}

public struct BottleCreationResult {
    public let bottle: Bottle
    public let registry: BottleData
}

/// The shared create-and-initialize operation used by SwiftUI and GPUI clients.
public enum BottleCreationService {
    public typealias RuntimeAvailabilityCheck = @MainActor () -> Bool
    public typealias LocationValidator = @MainActor (URL) -> BottleLocationValidation.ValidationResult
    public typealias PrefixBootstrapper = @MainActor (Bottle) async throws -> Void
    public typealias BottleCreatedHandler = @MainActor (Bottle) -> Void

    @MainActor
    public static func create(
        name: String,
        windowsVersion: WinVersion,
        parentDirectory: URL,
        destinationDirectory: URL,
        registry: BottleData,
        runtimeIsAvailable: @escaping RuntimeAvailabilityCheck = {
            WhiskyWineInstaller.isWhiskyWineInstalled()
        },
        validateLocation: @escaping LocationValidator = {
            BottleLocationValidation.validate(at: $0)
        },
        bootstrapPrefix: @escaping PrefixBootstrapper = {
            try await Wine.configureNewBottlePrefix(bottle: $0)
        },
        onBottleCreated: @escaping BottleCreatedHandler = { _ in }
    ) async throws -> BottleCreationResult {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw BottleCreationServiceError.emptyName }
        guard destinationDirectory.isFileURL, parentDirectory.isFileURL,
              destinationDirectory.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
              == parentDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        else {
            throw BottleCreationServiceError.directoryCreationFailed
        }
        guard runtimeIsAvailable() else { throw BottleCreationServiceError.runtimeMissing }

        let locationResult = validateLocation(parentDirectory)
        guard locationResult == .valid else {
            throw BottleCreationServiceError.locationUnsuitable(locationResult)
        }

        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destinationDirectory.path) else {
            throw BottleCreationServiceError.directoryCreationFailed
        }
        do {
            try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        } catch { throw BottleCreationServiceError.directoryCreationFailed }
        guard mkdir(destinationDirectory.path, mode_t(0o755)) == 0 else {
            throw BottleCreationServiceError.directoryCreationFailed
        }
        let createdIdentity = try fileManager
            .attributesOfItem(atPath: destinationDirectory.path)[.systemFileNumber] as? NSNumber

        let bottle = Bottle(bottleUrl: destinationDirectory, inFlight: true)
        bottle.settings.windowsVersion = windowsVersion
        bottle.settings.name = name
        onBottleCreated(bottle)

        do {
            try await bootstrapPrefix(bottle)
            bottle.saveBottleSettings()
            SettingsPersistence.shared.flush()

            let metadataURL = destinationDirectory.appending(path: "Metadata").appendingPathExtension("plist")
            guard let data = try? Data(contentsOf: metadataURL),
                  let persisted = try? PropertyListDecoder().decode(BottleSettings.self, from: data),
                  persisted.name == name, persisted.windowsVersion == windowsVersion
            else {
                throw BottleCreationServiceError.metadataCreationFailed
            }

            var updatedRegistry = registry
            guard updatedRegistry.registerBottlePath(destinationDirectory) else {
                throw BottleCreationServiceError.registrySaveFailed
            }
            return BottleCreationResult(bottle: bottle, registry: updatedRegistry)
        } catch {
            SettingsPersistence.shared.flush()
            let currentIdentity = (try? fileManager
                .attributesOfItem(atPath: destinationDirectory.path))?[.systemFileNumber] as? NSNumber
            if createdIdentity != nil, currentIdentity == createdIdentity {
                try? fileManager.removeItem(at: destinationDirectory)
            }
            throw error
        }
    }
}
