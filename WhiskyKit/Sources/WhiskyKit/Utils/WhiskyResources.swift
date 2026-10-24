//
//  WhiskyResources.swift
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

/// Runtime tools live in the application resources, beside a packaged bridge helper.
public enum WhiskyResources {
    public static func tool(_ name: String) -> URL? {
        guard ["cabextract", "winetricks", "verbs.txt"].contains(name) else { return nil }
        let executable = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let directories = [Bundle.main.resourceURL, executable.deletingLastPathComponent()].compactMap { $0 }
        return directories.map { $0.appendingPathComponent(name) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public static var kitBundleURL: URL {
        Bundle.module.bundleURL
    }
}
