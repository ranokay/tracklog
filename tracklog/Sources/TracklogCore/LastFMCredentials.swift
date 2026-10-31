import Foundation

/// One Last.fm application pair: an API key with the shared secret that signs
/// its requests.
///
/// Source builds include no application pair. Save your own pair through
/// Tracklog settings; the credential provider reads it from the Keychain.
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

    /// An unconfigured fallback: Last.fm requests require a user-supplied pair.
    public static let compiled = LastFMAppCredentials(apiKey: "", sharedSecret: "")
}
