//
//  InstalledPrograms.swift
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

public enum InstalledPrograms {
    public static let noiseExecutableNames: Set<String> = [
        "steamerrorreporter.exe",
        "steamerrorreporter64.exe",
        "steamservice.exe",
        "steamwebhelper.exe",
        "steam_monitor.exe",
        "steamsysinfo.exe",
        "steamxboxutil.exe",
        "crashreporter.exe",
        "crashhandler.exe",
        "crashpad_handler.exe",
        "gameoverlayui.exe",
        "gameoverlayui64.exe",
        "fossilize-replay.exe",
        "fossilize-replay64.exe",
        "gldriverquery.exe",
        "gldriverquery64.exe",
        "hardwareupdater.exe",
        "secure_desktop_capture.exe",
        "writeminidump.exe",
        "vc_redist.x86.exe",
        "vc_redist.x64.exe",
        "vcredist_x86.exe",
        "vcredist_x64.exe",
        "ueprereqsetup_x86.exe",
        "ueprereqsetup_x64.exe",
        "crossover html engine.exe"
    ]

    /// Walks the bottle's `Program Files` directories and returns the URLs of
    /// installed `.exe` files, excluding ClickOnce cache artifacts, known noise
    /// executables, and anything in `blocklist`.
    ///
    /// This is a pure filesystem read with no actor-isolated state, so callers
    /// can run it off the main actor — it's the heavy part of repopulating
    /// ``programs`` for a large bottle.
    ///
    /// - Parameters:
    ///   - driveC: The bottle's `drive_c` directory.
    ///   - blocklist: User-blocked program URLs to omit.
    /// - Returns: Discovered executable URLs in filesystem-enumeration order.
    public static func discoverInstalledExecutables(
        driveC: URL,
        blocklist: Set<URL>
    ) -> [URL] {
        var found: [URL] = []
        let canonicalBlocklist = Set(blocklist.map { $0.resolvingSymlinksInPath().standardizedFileURL })
        for folderName in ["Program Files", "Program Files (x86)", "Program Files (Arm)"] {
            let folderURL = CaseInsensitivePath.resolve(base: driveC, components: [folderName])
            let enumerator = FileManager.default.enumerator(
                at: folderURL, includingPropertiesForKeys: [.isExecutableKey], options: [.skipsHiddenFiles]
            )

            while let url = enumerator?.nextObject() as? URL {
                guard !url.hasDirectoryPath, url.pathExtension.lowercased() == "exe" else { continue }
                // Skip ClickOnce cache executables (noisy internal artifacts)
                guard !url.path.lowercased().contains("/apps/2.0/") else { continue }
                // Skip known launcher helpers and crash reporters that pollute the list
                let canonical = url.resolvingSymlinksInPath().standardizedFileURL
                guard !noiseExecutableNames.contains(url.lastPathComponent.lowercased()),
                      !canonicalBlocklist.contains(canonical)
                else { continue }
                found.append(url)
            }
        }
        return found
    }
}
