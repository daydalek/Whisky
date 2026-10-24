// swift-tools-version: 6.0
//
//  Package.swift
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

import PackageDescription

var dependencies: [Package.Dependency] = [.package(path: "../WhiskyCore"), .package(path: "../WhiskyMetadata")]
var hostDependencies: [Target.Dependency] = ["WhiskyApplication", "WhiskyBridgeProtocol"]
var nativeTargets: [Target] = []
var hostToolProducts: [Product] = []
#if os(Linux)
nativeTargets += [
    .systemLibrary(name: "CGtk4", pkgConfig: "gtk4"),
    .executableTarget(name: "WhiskyFilePicker", dependencies: ["CGtk4"]),
    .executableTarget(name: "WhiskyHostCommand")
]
hostToolProducts = [
    .executable(name: "whisky-file-picker", targets: ["WhiskyFilePicker"]),
    .executable(name: "whisky-host-command", targets: ["WhiskyHostCommand"])
]
#endif
#if os(macOS)
dependencies.append(.package(path: "../WhiskyKit"))
hostDependencies.append("WhiskyNativeBridge")
nativeTargets.append(.target(name: "WhiskyNativeBridge", dependencies: [
    "WhiskyApplication", "WhiskyBridgeProtocol", "WhiskyCore",
    .product(name: "WhiskyKit", package: "WhiskyKit")
]))
nativeTargets.append(.testTarget(name: "WhiskyNativeBridgeTests", dependencies: [
    "WhiskyNativeBridge", "WhiskyApplication", "WhiskyBridgeProtocol", "WhiskyCore",
    .product(name: "WhiskyKit", package: "WhiskyKit")
]))
#endif

let package = Package(
    name: "WhiskyBridge",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WhiskyBridgeProtocol", targets: ["WhiskyBridgeProtocol"]),
        .library(name: "WhiskyApplication", targets: ["WhiskyApplication"]),
        .executable(name: "whisky-bridge", targets: ["WhiskyBridgeHost"])
    ] + hostToolProducts,
    dependencies: dependencies,
    targets: [
        .target(name: "WhiskyBridgeProtocol"),
        .target(name: "CHostCommand"),
        .target(
            name: "WhiskyApplication",
            dependencies: [
                "WhiskyBridgeProtocol",
                "WhiskyCore",
                "CHostCommand",
                .product(name: "WhiskyMetadata", package: "WhiskyMetadata")
            ],
            resources: [.copy("Resources/linux-wine-archive.py")]
        ),
        .executableTarget(name: "WhiskyBridgeHost", dependencies: hostDependencies),
        .testTarget(
            name: "WhiskyBridgeTests",
            dependencies: [
                "WhiskyApplication",
                "WhiskyBridgeProtocol",
                "WhiskyCore",
                .product(name: "WhiskyMetadata", package: "WhiskyMetadata")
            ]
        )
    ] + nativeTargets,
    swiftLanguageModes: [.v6]
)
