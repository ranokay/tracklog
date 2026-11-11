import Foundation

// MARK: - Read fields

/// Only the fields the detail pages read are declared. Last.fm sends many
/// more (names, MBIDs, biographies, tags, similar artists, tracklists), and
/// an undeclared field cannot fail decoding.
struct LastFMImageValue: Decodable {
    let text: String?
    let size: String?

    enum CodingKeys: String, CodingKey {
        case text = "#text"
        case size
    }

    init(from decoder: any Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            text = nil
            size = nil
            return
        }
        text = container.lenient(String.self, forKey: .text)
        size = container.lenient(String.self, forKey: .size)
    }
}

struct LastFMStatsValue: Decodable {
    let listeners: LastFMFlexibleInt?
    let playcount: LastFMFlexibleInt?
    let userplaycount: LastFMFlexibleInt?

    enum CodingKeys: String, CodingKey {
        case listeners
        case playcount
        case userplaycount
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        listeners = container.lenient(LastFMFlexibleInt.self, forKey: .listeners)
        playcount = container.lenient(LastFMFlexibleInt.self, forKey: .playcount)
        userplaycount = container.lenient(LastFMFlexibleInt.self, forKey: .userplaycount)
    }
}

// MARK: - Payloads

struct LastFMArtistInfoValue: Decodable {
    let url: String?
    let stats: LastFMStatsValue?

    enum CodingKeys: String, CodingKey {
        case url
        case stats
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = container.lenient(String.self, forKey: .url)
        stats = container.lenient(LastFMStatsValue.self, forKey: .stats)
    }
}

struct LastFMArtistInfoPayload: Decodable {
    let artist: LastFMArtistInfoValue?

    enum CodingKeys: String, CodingKey {
        case artist
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        artist = container.lenient(LastFMArtistInfoValue.self, forKey: .artist)
    }
}

struct LastFMAlbumInfoValue: Decodable {
    let url: String?
    let releasedate: String?
    let image: [LastFMImageValue]?
    let listeners: LastFMFlexibleInt?
    let playcount: LastFMFlexibleInt?
    let userplaycount: LastFMFlexibleInt?

    enum CodingKeys: String, CodingKey {
        case url
        case releasedate
        case image
        case listeners
        case playcount
        case userplaycount
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = container.lenient(String.self, forKey: .url)
        releasedate = container.lenient(String.self, forKey: .releasedate)
        image = container.lenient([LastFMImageValue].self, forKey: .image)
        listeners = container.lenient(LastFMFlexibleInt.self, forKey: .listeners)
        playcount = container.lenient(LastFMFlexibleInt.self, forKey: .playcount)
        userplaycount = container.lenient(LastFMFlexibleInt.self, forKey: .userplaycount)
    }
}

struct LastFMAlbumInfoPayload: Decodable {
    let album: LastFMAlbumInfoValue?

    enum CodingKeys: String, CodingKey {
        case album
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        album = container.lenient(LastFMAlbumInfoValue.self, forKey: .album)
    }
}

struct LastFMTrackInfoValue: Decodable {
    let url: String?
    let duration: LastFMFlexibleInt?
    let listeners: LastFMFlexibleInt?
    let playcount: LastFMFlexibleInt?
    let userplaycount: LastFMFlexibleInt?

    enum CodingKeys: String, CodingKey {
        case url
        case duration
        case listeners
        case playcount
        case userplaycount
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = container.lenient(String.self, forKey: .url)
        duration = container.lenient(LastFMFlexibleInt.self, forKey: .duration)
        listeners = container.lenient(LastFMFlexibleInt.self, forKey: .listeners)
        playcount = container.lenient(LastFMFlexibleInt.self, forKey: .playcount)
        userplaycount = container.lenient(LastFMFlexibleInt.self, forKey: .userplaycount)
    }
}

struct LastFMTrackInfoPayload: Decodable {
    let track: LastFMTrackInfoValue?

    enum CodingKeys: String, CodingKey {
        case track
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        track = container.lenient(LastFMTrackInfoValue.self, forKey: .track)
    }
}

private extension KeyedDecodingContainer {
    /// A field can arrive in a shape other than the documented one. An
    /// unreadable optional value becomes absent, so that field is tolerated
    /// without discarding the facts around it.
    func lenient<Value: Decodable>(_ type: Value.Type, forKey key: Key) -> Value? {
        try? decodeIfPresent(type, forKey: key)
    }
}
