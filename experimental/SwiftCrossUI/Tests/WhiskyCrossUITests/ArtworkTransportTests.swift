//
//  ArtworkTransportTests.swift
//  WhiskyCrossUITests
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
import Testing
import WhiskyCore
@testable import WhiskyCrossUI

struct ArtworkTransportTests {
    @Test func portableAssetDecodesAndResizesInTheToolkitAdapter() throws {
        // PNG fixture: 256 x 32 opaque green, generated with PNG chunks and zlib.
        let encoded = """
        iVBORw0KGgoAAAANSUhEUgAAAQAAAAAgCAYAAAD9qabkAAAAgElEQVR4nO3OMREAAAgAIfuX1hg/yFGAmQXeygNAJw8AnTwA
        dPIA0MkDQCcPAJ08AHTyANDJA0AnDwCdPAB08gDQyQNAJw8AnTwAdPIA0MkDQCcPAJ08AHTyANDJA0AnDwCdPAB08gDQyQNA
        Jw8AnTwAdPIA0MkDQCcPAJ08AGQO+AXDsnYIhdcAAAAASUVORK5CYII=
        """.replacingOccurrences(of: "\n", with: "")
        let data = try #require(Data(base64Encoded: encoded))
        let decoded = try #require(decodeArtworkThumbnail(ArtworkAsset(data: data)))
        #expect(decoded.width == 128)
        #expect(decoded.height == 16)
        #expect(decoded.pixels.first == RGBA(0, 255, 0, 255))
        #expect(decodeArtworkThumbnail(ArtworkAsset(data: Data("invalid".utf8))) == nil)
        var oversized = data
        oversized[16] = 127
        #expect(decodeArtworkThumbnail(ArtworkAsset(data: oversized)) == nil)
    }
}
