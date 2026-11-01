import Foundation

// MARK: - Payloads

struct ErrorPayload: Decodable {
    let error: Int?
    let message: String?
}

struct TokenPayload: Decodable {
    let token: String?
}

struct SessionPayload: Decodable {
    let session: SessionValue?
}

struct SessionValue: Decodable {
    let name: String?
    let key: String?
}

struct UserPayload: Decodable {
    let user: UserValue?
}

struct UserValue: Decodable {
    let name: String?
    let playcount: String?
}

// MARK: - Charts

/// Last.fm returns counts and ranks as strings in JSON. A small flexible
/// decoder keeps both string and numeric fixtures readable.
struct LastFMFlexibleInt: Decodable {
    let value: Int?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            value = number
        } else if let text = try? container.decode(String.self) {
            value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            value = nil
        }
    }
}

struct LastFMRankValue: Decodable {
    let rank: LastFMFlexibleInt?

    enum CodingKeys: String, CodingKey {
        case rank
    }
}

struct LastFMChartArtistValue: Decodable {
    let name: String?
    let mbid: String?
}

struct LastFMChartEntry: Decodable {
    let name: String?
    let playcount: LastFMFlexibleInt?
    let mbid: String?
    let artist: LastFMChartArtistValue?
    let attr: LastFMRankValue?

    enum CodingKeys: String, CodingKey {
        case name
        case playcount
        case mbid
        case artist
        case attr = "@attr"
    }
}

struct LastFMTopArtistsPayload: Decodable {
    let topartists: LastFMTopArtistsValue?
}

/// Last.fm can return a single ranked entry as an object and several as an
/// array. Both are valid JSON for the same response field.
struct LastFMChartEntryList: Decodable {
    let entries: [LastFMChartEntry]

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let list = try? container.decode([LastFMChartEntry].self) {
            entries = list
        } else {
            entries = try [container.decode(LastFMChartEntry.self)]
        }
    }
}

struct LastFMTopArtistsValue: Decodable {
    let artist: LastFMChartEntryList?
}

struct LastFMTopAlbumsPayload: Decodable {
    let topalbums: LastFMTopAlbumsValue?
}

struct LastFMTopAlbumsValue: Decodable {
    let album: LastFMChartEntryList?
}

struct LastFMTopTracksPayload: Decodable {
    let toptracks: LastFMTopTracksValue?
}

struct LastFMTopTracksValue: Decodable {
    let track: LastFMChartEntryList?
}

struct ScrobblePayload: Decodable {
    let scrobbles: ScrobblesValue?
}

struct ScrobblesValue: Decodable {
    let scrobble: ScrobbleList?
}

enum ScrobbleList: Decodable {
    case one(ScrobbleValue)
    case many([ScrobbleValue])

    var items: [ScrobbleValue] {
        switch self {
        case let .one(value): [value]
        case let .many(values): values
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let values = try? container.decode([ScrobbleValue].self) {
            self = .many(values)
        } else {
            self = try .one(container.decode(ScrobbleValue.self))
        }
    }
}

struct ScrobbleValue: Decodable {
    let ignoredMessage: IgnoredMessage?
}

struct IgnoredMessage: Decodable {
    let code: Int?

    enum CodingKeys: String, CodingKey {
        case code
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? container.decode(String.self, forKey: .code) {
            guard let value = Int(text) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .code,
                    in: container,
                    debugDescription: "The ignored code is not an integer.",
                )
            }
            code = value
        } else {
            code = try container.decode(Int.self, forKey: .code)
        }
    }
}
