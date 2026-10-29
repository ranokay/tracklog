import Foundation

/// One Last.fm application pair: an API key with the shared secret that signs
/// its requests.
///
/// ``compiled`` is Tracklog's own registered application. It is public by
/// design: the protocol needs the shared secret in the client to sign calls. A
/// listener's Keychain override uses the same type. The provisioning file at
/// `~/.config/tracklog/lastfm.json` is a development source only; nothing reads
/// it at runtime.
public struct LastFMAppCredentials: Equatable, Sendable, CustomStringConvertible {
    public let apiKey: String
    public let sharedSecret: String

    public init(apiKey: String, sharedSecret: String) {
        self.apiKey = apiKey
        self.sharedSecret = sharedSecret
    }

    /// Whether both halves are present. A missing half cannot sign a call.
    public var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !sharedSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Redacted so a log line, diagnostic dump or export cannot carry the pair.
    public var description: String {
        isConfigured ? "Last.fm app credentials (configured)" : "Last.fm app credentials (missing)"
    }

    public static let compiled = LastFMAppCredentials(
        apiKey: "84615dace7f506755d157a1102347bd5",
        sharedSecret: "a424fc0be178c5d13cc5dc6e7445fa96",
    )
}
