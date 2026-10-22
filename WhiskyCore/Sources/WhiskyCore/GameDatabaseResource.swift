//
//  GameDatabaseResource.swift
//  WhiskyCore
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

private final class GameDatabaseResourceAnchor {}

/// Locates the canonical database beside executables or in application resource bundles.
public enum GameDatabaseResource {
    public static func data(searchDirectories: [URL]? = nil) throws -> Data {
        let directories = searchDirectories ?? defaults()
        for directory in directories {
            for name in ["WhiskyCore_WhiskyCore.resources", "WhiskyCore_WhiskyCore.bundle"] {
                let bundle = directory.appendingPathComponent(name)
                for relative in ["GameDB.json", "Contents/Resources/GameDB.json"] {
                    let url = bundle.appendingPathComponent(relative)
                    if FileManager.default.fileExists(atPath: url.path) {
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= 8 * 1_024 * 1_024 else { throw CocoaError(.fileReadTooLarge) }
                        return try Data(contentsOf: url)
                    }
                }
            }
        }
        throw CocoaError(.fileReadNoSuchFile)
    }

    public static func identities(in data: Data) throws -> [GameIdentityRecord] {
        guard data.count <= 8 * 1_024 * 1_024 else { throw CocoaError(.fileReadTooLarge) }
        struct Document: Decodable {
            let version: Int
            let entries: [GameIdentityRecord]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(Document.self, from: data)
        let ids = document.entries.map(\.id)
        guard document.version == 1, Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return document.entries
    }

    private static func defaults() -> [URL] {
        var result = [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap { $0 }
        #if os(macOS)
        let module = Bundle(for: GameDatabaseResourceAnchor.self)
        result += [module.resourceURL, module.bundleURL].compactMap { $0 }
        #endif
        var executable = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        for _ in 0 ..< 5 {
            executable.deleteLastPathComponent()
            result.append(executable)
            result.append(executable.appendingPathComponent("Resources"))
        }
        return result
    }
}
