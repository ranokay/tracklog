import Foundation

/// How one service varies the Last.fm 2.0 protocol. Method names, form
/// encoding and response shapes are shared; the signature, the batch limit and
/// the authorization page are not.
public enum LastFMProtocolDialect: String, Equatable, Sendable {
    /// Last.fm itself: every call is signed, and one post carries up to fifty
    /// scrobbles.
    case lastFM = "lastfm"
    /// GNU FM, as Libre.fm runs it: unsigned calls, one scrobble per post.
    case gnuFM = "gnufm"

    /// Whether a call carries `api_sig`. GNU FM accepts a signature but does
    /// not require one, so the dialect omits it rather than computing it from
    /// a secret the service never issues.
    public var signsRequests: Bool {
        self == .lastFM
    }

    /// Whether the application pair needs a shared secret. GNU FM identifies a
    /// client by its key alone.
    public var requiresSharedSecret: Bool {
        signsRequests
    }

    /// The protocol's hard limit for one `track.scrobble` request. GNU FM
    /// accepts one scrobble per post.
    public var maximumScrobblesPerBatch: Int {
        switch self {
        case .lastFM: 50
        case .gnuFM: 1
        }
    }

    /// The page a listener authorizes a request token on. GNU FM serves it
    /// under the root the listener scrobbles to.
    func authorizationURL(
        endpoint: ServiceEndpoint,
        token: String,
        apiKey: String,
    ) -> URL? {
        let root = switch self {
        case .lastFM: LastFMWebEndpoint.authorizationRoot
        case .gnuFM: "\(endpoint.description)/api/auth/"
        }
        var components = URLComponents(string: root)
        components?.queryItems = [
            URLQueryItem(
                name: "api_key",
                value: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            ),
            URLQueryItem(name: "token", value: token),
        ]
        return components?.url
    }
}

/// GNU FM identifies a client by one 32-character key. The key is public by
/// design: every request carries it, and it is never a secret.
///
/// Libre.fm registers a key against the service before it will issue request
/// tokens, and registration needs an account, so it happens outside the build.
/// The compiled value is a placeholder until that registration lands: linking
/// ends with the service's invalid-key answer and nothing is sent.
public enum LibreFMClientKey {
    public static let compiled = "00000000000000000000000000000000"
}
