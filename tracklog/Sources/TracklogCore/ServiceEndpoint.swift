import Foundation

/// The protocol family a connection speaks. The raw values are persisted, so
/// one is never renamed.
public enum ServiceKind: String, CaseIterable, Identifiable, Sendable {
    case lastFM = "lastfm"
    case libreFM = "librefm"
    case listenBrainz = "listenbrainz"

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .lastFM: "Last.fm"
        case .libreFM: "Libre.fm"
        case .listenBrainz: "ListenBrainz"
        }
    }

    /// The root every request for this service is built from. Fixed for
    /// Last.fm and ListenBrainz; a Libre.fm connection keeps the root the
    /// listener entered, and this is the default it starts from.
    public var defaultEndpoint: ServiceEndpoint {
        switch self {
        case .lastFM: .lastFM
        case .libreFM: .libreFM
        case .listenBrainz: .listenBrainz
        }
    }
}

/// One normalized service root. Two connections on the same kind and endpoint
/// address the same account slot, so the pair is unique.
///
/// Normalization lowercases the scheme and host, drops the HTTPS default port
/// and a trailing slash, and refuses anything but a plain HTTPS root: no
/// credentials in the URL, no query, no fragment, no local HTTP.
public struct ServiceEndpoint: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public var description: String {
        rawValue
    }

    public init?(normalizing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else { return nil }

        components.scheme = "https"
        components.host = host
        if components.port == 443 {
            components.port = nil
        }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") {
            path.removeLast()
        }
        components.percentEncodedPath = path
        guard let url = components.url else { return nil }
        rawValue = url.absoluteString
    }

    private init(validated rawValue: String) {
        self.rawValue = rawValue
    }

    public static let lastFM = ServiceEndpoint(validated: "https://ws.audioscrobbler.com")
    public static let libreFM = ServiceEndpoint(validated: "https://libre.fm")
    public static let listenBrainz = ServiceEndpoint(validated: "https://api.listenbrainz.org")
}
