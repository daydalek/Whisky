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
        try resource("GameDB.json", searchDirectories: searchDirectories)
    }

    public static func resource(_ file: String, searchDirectories: [URL]? = nil) throws -> Data {
        for directory in searchDirectories ?? defaults() {
            let candidates = [directory]
                + ["WhiskyCore_WhiskyCore.resources", "WhiskyCore_WhiskyCore.bundle", "Contents/Resources"]
                .map { directory.appendingPathComponent($0) }
            for base in candidates {
                for relative in [file, "Resources/\(file)", "Contents/Resources/\(file)"] {
                    let url = base.appendingPathComponent(relative)
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
        #if DEBUG
        // swift-test places resources in layouts that differ per toolchain
        // (.build/debug vs .build/<triple>/debug, scratch run directories), so
        // the executable walk-up below misses them on some runners. The
        // checked-out sources exist on every machine that compiled this binary
        // and locate the resource deterministically in development builds.
        let sourceRoot = URL(fileURLWithPath: #filePath) // …/WhiskyCore/Sources/WhiskyCore/GameDatabaseResource.swift
            .deletingLastPathComponent() // …/Sources/WhiskyCore
        if FileManager.default.fileExists(atPath: sourceRoot.appendingPathComponent("Resources").path) {
            result.insert(sourceRoot, at: 0)
        }
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
