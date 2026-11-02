//
//  PublicGameMetadataProvider+Models.swift
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

import Foundation

struct BangumiImages: Decodable {
    let large: URL?
    let common: URL?
    let medium: URL?
    let grid: URL?
}

struct BangumiSubject: Decodable {
    let id: Int
    let name: String
    let nameCN: String?
    let summary: String?
    let date: String?
    let images: BangumiImages?

    enum CodingKeys: String, CodingKey {
        case id, name, summary, date, images
        case nameCN = "name_cn"
    }
}

struct BangumiResponse: Decodable {
    let data: [BangumiSubject]
}

private struct BangumiCharacter: Decodable {
    let id: Int
    let name: String
    let relation: String?
    let images: BangumiImages?
}

private struct VNDBCharacters: Decodable {
    let more: Bool
    let results: [VNDBCharacter]
}

struct VNDBCharacter: Decodable {
    struct Appearance: Decodable {
        let id: String
        let role: String?
    }

    let id: String
    let name: String
    let original: String?
    let image: VNDBImage?
    let vns: [Appearance]?
}

struct VNDBVAItem: Decodable {
    let note: String?
    let character: VNDBCharInfo?
    let staff: VNDBStaffInfo?
}

struct VNDBCharInfo: Decodable {
    struct Appearance: Decodable {
        let id: String
        let role: String?
    }

    let vns: [Appearance]?
    let id: String
    let name: String
    let original: String?
    let description: String?
    let image: VNDBImage?
}

struct VNDBStaffInfo: Decodable {
    let id: String
    let name: String
    let original: String?
}

struct VNDBNovelVA: Decodable {
    let id: String
    let title: String?
    let voiceActors: [VNDBVAItem]?

    enum CodingKeys: String, CodingKey {
        case id, title
        case voiceActors = "va"
    }
}

struct VNDBNovelVAPage: Decodable {
    let results: [VNDBNovelVA]
}

struct VNDBCharInfoPage: Decodable {
    let results: [VNDBCharInfo]
}

struct BangumiActor: Decodable {
    let id: Int?
    let name: String
}

struct BangumiCharacterFull: Decodable {
    let id: Int
    let name: String
    let relation: String?
    let images: BangumiImages?
    let summary: String?
    let actors: [BangumiActor]?
}

struct VNDBTitle: Decodable {
    let title: String
    let lang: String
    let latin: String?
    let main: Bool?
}

struct VNDBImage: Decodable { let url: URL? }

struct VNDBDeveloper: Decodable {
    let name: String
    let original: String?
}

struct VNDBNovel: Decodable {
    let id: String
    let title: String
    let titles: [VNDBTitle]?
    let alttitle: String?
    let aliases: [String]?
    let description: String?
    let released: String?
    let image: VNDBImage?
    let developers: [VNDBDeveloper]?
}

struct VNDBResponse: Decodable {
    let results: [VNDBNovel]
}

struct SteamItem: Decodable {
    let id: Int
    let name: String
    let tinyImage: URL?

    enum CodingKeys: String, CodingKey {
        case id, name
        case tinyImage = "tiny_image"
    }
}

struct SteamResponse: Decodable {
    let items: [SteamItem]
}

struct SteamReleaseDate: Decodable { let date: String? }

struct SteamDetails: Decodable {
    let name: String
    let shortDescription: String?
    let developers: [String]?
    let releaseDate: SteamReleaseDate?

    enum CodingKeys: String, CodingKey {
        case name, developers
        case shortDescription = "short_description"
        case releaseDate = "release_date"
    }
}

struct SteamDetailResponse: Decodable {
    let success: Bool
    let data: SteamDetails?
}
