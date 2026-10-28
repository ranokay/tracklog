import Foundation
@testable import TracklogCore

// MARK: - Requests

/// Parses an `application/x-www-form-urlencoded` body into its parameters.
func formParameters(_ request: HTTPRequest) -> [String: String] {
    guard let body = request.body, let text = String(data: body, encoding: .utf8) else { return [:] }
    return text.split(separator: "&").reduce(into: [:]) { result, pair in
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let name = String(parts[0]).removingPercentEncoding,
              let value = String(parts[1]).removingPercentEncoding
        else { return }
        result[name] = value
    }
}

func signedParameters(_ parameters: [String: String], secret: String) -> String {
    LastFMSignature.signature(parameters: parameters, sharedSecret: secret)
}

// MARK: - Responses

func lastFMTokenResponse(_ token: String = "request-token") -> HTTPResponse {
    HTTPResponse(statusCode: 200, body: Data(#"{"token":"\#(token)"}"#.utf8))
}

func lastFMSessionResponse(
    name: String = "listener",
    key: String = "session-key",
) -> HTTPResponse {
    HTTPResponse(
        statusCode: 200,
        body: Data(#"{"session":{"name":"\#(name)","key":"\#(key)","subscriber":0}}"#.utf8),
    )
}

func lastFMUserResponse(name: String = "listener") -> HTTPResponse {
    HTTPResponse(statusCode: 200, body: Data(#"{"user":{"name":"\#(name)"}}"#.utf8))
}

/// One Last.fm scrobble response with the given ignored codes, in order.
func lastFMScrobbleResponse(codes: [Int]) -> HTTPResponse {
    let scrobbles = codes.enumerated().map { index, code in
        #"""
        {
          "artist":{"#text":"Artist \#(index)","corrected":"0"},
          "album":{"#text":"","corrected":"0"},
          "track":{"#text":"Track \#(index)","corrected":"0"},
          "albumArtist":{"#text":"","corrected":"0"},
          "timestamp":"\#(1_000_000 + index)",
          "ignoredMessage":{"code":"\#(code)","#text":""}
        }
        """#
    }
    let value = codes.count == 1 ? scrobbles[0] : "[\(scrobbles.joined(separator: ","))]"
    return HTTPResponse(
        statusCode: 200,
        body: Data(#"{"scrobbles":{"@attr":{"accepted":0,"ignored":0},"scrobble":\#(value)}}"#.utf8),
    )
}

func lastFMErrorResponse(
    code: Int,
    message: String = "The service rejected the request.",
    statusCode: Int = 200,
) -> HTTPResponse {
    HTTPResponse(
        statusCode: statusCode,
        body: Data(#"{"error":\#(code),"message":"\#(message)"}"#.utf8),
    )
}

func lastFMEmptyResponse() -> HTTPResponse {
    HTTPResponse(statusCode: 200, body: Data("{}".utf8))
}

// MARK: - Fixtures

let lastFMTestCredentials = LastFMAppCredentials(
    apiKey: "xxxxxxxxxx",
    sharedSecret: "ilovecher",
)

func lastFMTestConnection(identity: String = "listener") -> Connection {
    Connection(
        kind: .lastFM,
        endpoint: .lastFM,
        identity: identity,
        createdAt: Date(timeIntervalSince1970: 1_000_000),
    )
}

func lastFMTestListen(
    index: Int = 0,
    title: String? = nil,
    artist: String? = nil,
    album: String = "",
    albumArtist: String = "",
    duration: TimeInterval = 200,
    start: Date = Date(timeIntervalSince1970: 1_000_000),
) -> Listen {
    Listen(
        raw: ListenMetadata(
            title: title ?? "Track \(index)",
            artist: artist ?? "Artist \(index)",
            album: album,
            albumArtist: albumArtist,
        ),
        processed: ListenMetadata(
            title: title ?? "Track \(index)",
            artist: artist ?? "Artist \(index)",
            album: album,
            albumArtist: albumArtist,
        ),
        bundleID: "com.apple.Music",
        duration: duration,
        playedDuration: duration / 2,
        startedAt: start.addingTimeInterval(Double(index)),
        capturedAt: start.addingTimeInterval(Double(index)),
    )
}

func lastFMTestTrack(
    title: String = "Heart of Glass",
    artist: String = "Blondie",
    album: String = "Parallel Lines",
    albumArtist: String = "Blondie",
    duration: TimeInterval = 225.4,
) -> Track {
    Track(
        title: title,
        artist: artist,
        album: album,
        albumArtist: albumArtist,
        duration: duration,
        bundleID: "com.apple.Music",
    )
}
