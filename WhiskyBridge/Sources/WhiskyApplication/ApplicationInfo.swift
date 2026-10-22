//
//  ApplicationInfo.swift
//  WhiskyApplication
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
import WhiskyBridgeProtocol

/// `system.info`: packaged application metadata for the About panel. Read from
/// the helper's bundle, which lives inside the same `.app` as every frontend, so
/// the version is the packaged product version rather than the protocol version.
public enum ApplicationInfo {
    public static func payload() -> JSONValue {
        let bundle = Bundle.main
        let info = bundle.infoDictionary
        let name = info?["CFBundleName"] as? String ?? "Whisky"
        let version = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? ""
        let identifier = bundle.bundleIdentifier ?? "com.franke.Whisky"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        return .object([
            "appName": .string(name),
            "appVersion": .string(version),
            "build": .string(build),
            "bundleIdentifier": .string(identifier),
            "osVersion": .string(osVersion)
        ])
    }
}
