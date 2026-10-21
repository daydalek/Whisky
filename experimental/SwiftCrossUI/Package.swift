// swift-tools-version: 6.0
//
//  Package.swift
//  WhiskyCrossUI
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

import PackageDescription

let package = Package(
    name: "WhiskyCrossUI",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "WhiskyCrossUI", targets: ["WhiskyCrossUI"])],
    dependencies: [
        .package(path: "../../WhiskyCore"),
        .package(path: "../../WhiskyBridge"),
        .package(path: "../../WhiskyKit"),
        .package(url: "https://github.com/stackotter/swift-image-formats", .upToNextMinor(from: "0.5.0")),
        .package(
            url: "https://github.com/moreSwift/swift-cross-ui",
            revision: "0f3ec3958b79cdc39a1a3e604516b71ab33a9043"
        )
    ],
    targets: [
        .executableTarget(
            name: "WhiskyCrossUI",
            dependencies: [
                "WhiskyCore",
                .product(name: "WhiskyApplication", package: "WhiskyBridge"),
                .product(name: "ImageFormats", package: "swift-image-formats"),
                .product(name: "WhiskyKit", package: "WhiskyKit", condition: .when(platforms: [.macOS])),
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                .product(name: "DefaultBackend", package: "swift-cross-ui"),
                .product(name: "AppKitBackend", package: "swift-cross-ui", condition: .when(platforms: [.macOS])),
                .product(name: "GtkBackend", package: "swift-cross-ui", condition: .when(platforms: [.linux])),
                .product(name: "Gtk", package: "swift-cross-ui", condition: .when(platforms: [.linux])),
                .product(name: "WinUIBackend", package: "swift-cross-ui", condition: .when(platforms: [.windows]))
            ]
        ),
        .testTarget(
            name: "WhiskyCrossUITests",
            dependencies: [
                "WhiskyCrossUI", "WhiskyCore",
                .product(name: "ImageFormats", package: "swift-image-formats"),
                .product(name: "WhiskyKit", package: "WhiskyKit", condition: .when(platforms: [.macOS]))
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
