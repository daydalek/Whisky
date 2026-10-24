//
//  LinuxWineRelease.swift
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

struct LinuxWineVersion: Codable, Comparable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ tag: String) {
        let raw = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let version = raw.hasSuffix("-linux-amd64") ? String(raw.dropLast(12)) : raw
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let major = Int(components[0]), let minor = Int(components[1]), let patch = Int(components[2])
        else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    var description: String {
        "\(major).\(minor).\(patch)"
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

struct LinuxWineReleaseAsset: Decodable, Sendable {
    let name: String
    let state: String
    let size: Int64
    let browserDownloadURL: URL
    let digest: String?
    enum CodingKeys: String, CodingKey {
        case name, state, size, digest
        case browserDownloadURL = "browser_download_url"
    }
}

struct LinuxWineRelease: Decodable, Sendable {
    let tagName: String
    let draft: Bool
    let assets: [LinuxWineReleaseAsset]
    enum CodingKeys: String, CodingKey {
        case draft, assets
        case tagName = "tag_name"
    }

    static let repository = "daydalek/ge-proton-macos-wine-poc"
    static let endpoint: URL = {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=100") else {
            preconditionFailure("The built-in Linux Wine endpoint must be a URL")
        }
        return url
    }()

    static let archiveName = "wine-linux-amd64.tar.gz"
    static let required = [archiveName, "linux-release-manifest.json", "SHA256SUMS-linux-amd64"]

    var version: LinuxWineVersion? {
        LinuxWineVersion(tagName)
    }

    static func select(_ data: Data) throws -> Self {
        let releases = try JSONDecoder().decode([Self].self, from: data)
        var chosen: (version: LinuxWineVersion, release: Self)?
        for release in releases {
            guard !release.draft, let version = release.version, required.allSatisfy({ name in
                release.assets.filter { $0.name == name && $0.state == "uploaded" }.count == 1
            })
            else { continue }
            if chosen.map({ version > $0.version }) ?? true {
                chosen = (version, release)
            }
        }
        guard let chosen else {
            throw BridgeFailure("release_unavailable", "No published Linux Wine release has the required assets")
        }
        return chosen.release
    }

    func asset(_ name: String, endpoint: URL) throws -> LinuxWineReleaseAsset {
        guard let asset = assets.first(where: { $0.name == name && $0.state == "uploaded" }) else {
            throw BridgeFailure("invalid_manifest", "Linux Wine release asset is missing: \(name)")
        }
        let origin = Self.isLoopback(endpoint)
            ? "\(endpoint.scheme ?? "http")://\(endpoint.host ?? "127.0.0.1")\(endpoint.port.map { ":\($0)" } ?? "")"
            : "https://github.com"
        let expected = "\(origin)/\(Self.repository)/releases/download/\(tagName)/\(name)"
        guard asset.browserDownloadURL.absoluteString == expected,
              asset.size > 0, asset.size <= (name == Self.archiveName ? 1_073_741_824 : 1_048_576)
        else { throw BridgeFailure("invalid_manifest", "Invalid Linux Wine release asset: \(name)") }
        return asset
    }

    static func isLoopback(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme) && ["127.0.0.1", "localhost"].contains(url.host)
    }

    static func checksums(_ data: Data) throws -> [String: String] {
        var result: [String: String] = [:]
        guard let text = String(data: data, encoding: .utf8) else {
            throw BridgeFailure("invalid_manifest", "Runtime checksums must use UTF-8")
        }
        for line in text.split(separator: "\n") {
            let pieces = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard pieces.count == 2 else { throw BridgeFailure("invalid_manifest", "Invalid runtime checksums") }
            let hash = String(pieces[0])
            let name = pieces[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "*", with: "")
            guard validHash(hash), result[name] == nil else {
                throw BridgeFailure("invalid_manifest", "Invalid or duplicate runtime checksum")
            }
            result[name] = hash
        }
        return result
    }

    static func validHash(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
}

struct LinuxWinePackageManifest: Decodable {
    let runtimeAsset: String
    let prefixArchitecture: String
    let entrypoints: [String: String]
    let target: String
    let validationMode: String?
    enum CodingKeys: String, CodingKey {
        case entrypoints, target
        case runtimeAsset = "runtime_asset"
        case prefixArchitecture = "prefix_architecture"
        case validationMode = "validation_mode"
    }

    func validate() throws {
        guard runtimeAsset == LinuxWineRelease.archiveName, prefixArchitecture == "win64",
              target.contains("x86_64"),
              entrypoints["wine"] == "run", entrypoints["loader"] == "bin/wine",
              entrypoints["wineserver"] == "bin/wineserver"
        else { throw BridgeFailure("invalid_manifest", "Unsupported Linux Wine package contract") }
    }
}
