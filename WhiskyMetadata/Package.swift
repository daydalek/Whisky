// swift-tools-version: 6.0
//
//  Package.swift
//  WhiskyMetadata
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

var imageDependencies: [Target.Dependency] = []
var imageTargets: [Target] = []
#if os(Linux)
imageDependencies.append("CGdkPixbuf")
imageTargets.append(.systemLibrary(name: "CGdkPixbuf", pkgConfig: "gdk-pixbuf-2.0"))
#endif

let package = Package(
    name: "WhiskyMetadata",
    platforms: [.macOS(.v13)],
    products: [.library(name: "WhiskyMetadata", targets: ["WhiskyMetadata"])],
    dependencies: [.package(path: "../WhiskyCore")],
    targets: [
        .target(name: "WhiskyMetadata", dependencies: [
            .product(name: "WhiskyCore", package: "WhiskyCore")
        ] + imageDependencies),
        .testTarget(name: "WhiskyMetadataTests", dependencies: ["WhiskyMetadata", "WhiskyCore"])
    ] + imageTargets,
    swiftLanguageModes: [.v6]
)
