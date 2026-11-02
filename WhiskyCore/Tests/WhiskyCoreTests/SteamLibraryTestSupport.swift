//
//  SteamLibraryTestSupport.swift
//  WhiskyKitTests
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
import Testing
@testable import WhiskyCore

func makeSteamLibraryACF(
    appId: Int, name: String, installDir: String, stateFlags: Int, lastPlayed: Int = 1_760_000_000
) -> String {
    """
    "AppState"
    {
        "appid"        "\(appId)"
        "name"        "\(name)"
        "installdir"        "\(installDir)"
        "StateFlags"        "\(stateFlags)"
        "buildid"        "1785187029"
        "SizeOnDisk"        "541968407"
        "LastPlayed"        "\(lastPlayed)"
    }
    """
}

/// Builds a fixture bottle: a default Steam install with one installed
/// game, one downloading game, one manifest whose install dir is missing,
/// plus a second library on D: (via dosdevices symlink) with another
/// installed game and a duplicate of the first game's App ID.
func makeSteamLibraryFixtureBottle() throws -> (bottle: URL, tempRoot: URL) {
    let fileManager = FileManager.default
    let tempRoot = fileManager.temporaryDirectory.appending(path: "steamlib_\(UUID().uuidString)")
    let bottle = tempRoot.appending(path: "bottle")
    let steamRoot = bottle.appending(path: "drive_c")
        .appending(path: "Program Files (x86)").appending(path: "Steam")
    let steamApps = steamRoot.appending(path: "steamapps")

    try fileManager.createDirectory(
        at: steamApps.appending(path: "common").appending(path: "Casualties Unknown Demo"),
        withIntermediateDirectories: true
    )
    try Data().write(to: steamRoot.appending(path: "steam.exe"))

    try Data(makeSteamLibraryACF(
        appId: 4_576_510, name: "Casualties: Unknown Demo",
        installDir: "Casualties Unknown Demo", stateFlags: 4
    ).utf8).write(to: steamApps.appending(path: "appmanifest_4576510.acf"))

    // Downloading: filtered by state
    try Data(makeSteamLibraryACF(appId: 999, name: "Downloading Game", installDir: "dl", stateFlags: 2).utf8)
        .write(to: steamApps.appending(path: "appmanifest_999.acf"))

    // Claims installed but common dir is missing: filtered
    try Data(makeSteamLibraryACF(appId: 777, name: "Ghost Game", installDir: "Ghost", stateFlags: 4).utf8)
        .write(to: steamApps.appending(path: "appmanifest_777.acf"))

    try makeSteamSecondLibrary(tempRoot: tempRoot, bottle: bottle)

    let config = steamRoot.appending(path: "config")
    try fileManager.createDirectory(at: config, withIntermediateDirectories: true)
    let vdf = """
    "libraryfolders"
    {
        "0"
        {
            "path"        "C:\\\\Program Files (x86)\\\\Steam"
        }
        "1"
        {
            "path"        "D:\\\\"
        }
    }
    """
    try Data(vdf.utf8).write(to: config.appending(path: "libraryfolders.vdf"))

    return (bottle, tempRoot)
}

/// A second library on D: reached through the dosdevices symlink, holding
/// another installed game plus a duplicate of the first library's App ID.
func makeSteamSecondLibrary(tempRoot: URL, bottle: URL) throws {
    let fileManager = FileManager.default
    let secondLibrary = tempRoot.appending(path: "second-library")
    let secondApps = secondLibrary.appending(path: "steamapps")
    try fileManager.createDirectory(
        at: secondApps.appending(path: "common").appending(path: "ELDEN RING"),
        withIntermediateDirectories: true
    )
    try Data(makeSteamLibraryACF(appId: 1_245_620, name: "ELDEN RING", installDir: "ELDEN RING", stateFlags: 4).utf8)
        .write(to: secondApps.appending(path: "appmanifest_1245620.acf"))

    try Data(makeSteamLibraryACF(
        appId: 4_576_510, name: "Casualties Duplicate",
        installDir: "ELDEN RING", stateFlags: 4
    ).utf8).write(to: secondApps.appending(path: "appmanifest_dup.acf"))

    let dosDevices = bottle.appending(path: "dosdevices")
    try fileManager.createDirectory(at: dosDevices, withIntermediateDirectories: true)
    try fileManager.createSymbolicLink(
        at: dosDevices.appending(path: "d:"),
        withDestinationURL: secondLibrary
    )
}
