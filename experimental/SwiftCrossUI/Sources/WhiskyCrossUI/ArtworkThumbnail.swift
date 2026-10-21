//
//  ArtworkThumbnail.swift
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

import Foundation
import ImageFormats
import SwiftCrossUI
import WhiskyCore

struct ArtworkThumbnail: View {
    let source: ArtworkSource?
    let provider: any ArtworkProviding
    @State private var image: ImageFormats.Image<RGBA>?

    var body: some View {
        Group {
            if let image {
                SwiftCrossUI.Image(image).resizable().aspectRatio(
                    Double(image.width) / Double(image.height),
                    contentMode: .fit
                )
            } else {
                Text("◇")
            }
        }
        .frame(width: 48, height: 48)
        .task(id: source) {
            image = nil
            guard let source, let asset = await provider.artwork(for: ArtworkRequest(source: source)) else { return }
            let decoded = await Task.detached { decodeArtworkThumbnail(asset) }.value
            guard !Task.isCancelled else { return }
            image = decoded
        }
    }
}

struct CoverArtwork: View {
    let source: ArtworkSource?
    let provider: any ArtworkProviding
    let width: Double
    let height: Double
    var cacheDirectory: URL?
    @State private var image: ImageFormats.Image<RGBA>?

    var body: some View {
        Group {
            if let image {
                SwiftCrossUI.Image(image).resizable()
                    .aspectRatio(Double(image.width) / Double(image.height), contentMode: .fit)
            } else {
                Text("◇").font(.system(size: 32)).foregroundColor(WhiskyStyle.secondary)
            }
        }
        .frame(width: width, height: height)
        .background(WhiskyStyle.selection.opacity(0.45))
        .task(id: source) {
            image = nil
            guard let source, let asset = await provider.artwork(for: ArtworkRequest(
                source: source, maxPixelSize: 640, cacheDirectory: cacheDirectory
            ))
            else { return }
            let decoded = await Task.detached { decodeArtworkThumbnail(asset, maxPixelSize: 640) }.value
            guard !Task.isCancelled else { return }
            image = decoded
        }
    }
}

func decodeArtworkThumbnail(_ asset: ArtworkAsset, maxPixelSize: Int = 128) -> ImageFormats.Image<RGBA>? {
    guard asset.isWithinDecodingBudget,
          let decoded = try? ImageFormats.Image<RGBA>.load(from: Array(asset.data)),
          decoded.width > 0, decoded.height > 0,
          let thumbnail = ArtworkPixels.thumbnail(
              rgba: decoded.bytes,
              width: decoded.width,
              height: decoded.height,
              maxPixelSize: maxPixelSize
          )
    else { return nil }
    return ImageFormats.Image<RGBA>(width: thumbnail.width, height: thumbnail.height, bytes: thumbnail.bytes)
}
