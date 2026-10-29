import Foundation

/// One user-supplied Last.fm application pair, kept in the credential store's
/// single app-credential slot.
///
/// The slot holds this value's JSON form, so the Keychain sees one generic
/// password rather than two. The page that writes it reports only whether an
/// override exists: neither half is ever shown back.
public struct LastFMAppCredentialOverride: Equatable, Sendable, CustomStringConvertible {
    public let apiKey: String
    public let sharedSecret: String

    /// Trims both halves and refuses an incomplete pair. A pair with an empty
    /// side cannot sign a Last.fm call.
    public init?(validating apiKey: String, sharedSecret: String) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = sharedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !secret.isEmpty else { return nil }
        self.apiKey = key
        self.sharedSecret = secret
    }

    /// Reads the slot's stored form. Any other value is treated as no
    /// override, so a corrupt item cannot break startup or a delivery.
    public init?(storedValue: String) {
        guard let data = storedValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(StoredPair.self, from: data),
              let value = Self(validating: decoded.apiKey, sharedSecret: decoded.sharedSecret)
        else { return nil }
        self = value
    }

    /// The form written to the one app-credential slot.
    public var storedValue: String {
        guard let data = try? JSONEncoder().encode(
            StoredPair(apiKey: apiKey, sharedSecret: sharedSecret),
        ), let value = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return value
    }

    public var credentials: LastFMAppCredentials {
        LastFMAppCredentials(apiKey: apiKey, sharedSecret: sharedSecret)
    }

    /// Redacted so a log line, diagnostic dump or export cannot carry the pair.
    public var description: String {
        "Last.fm app credential override (configured)"
    }

    private struct StoredPair: Codable {
        let apiKey: String
        let sharedSecret: String
    }
}

/// Where the effective Last.fm pair comes from.
public enum LastFMAppCredentialSource: Equatable, Sendable {
    case compiled
    case override
}

/// The effective Last.fm application pair at request time.
public protocol LastFMAppCredentialsProviding: Sendable {
    func appCredentials() async -> LastFMAppCredentials
}

/// Resolves the Keychain override when the user saved one and falls back to
/// the compiled pair. It reads the credential store per request so a change
/// made on the app-credentials page takes effect without rebuilding adapters.
public struct StoredLastFMAppCredentials: LastFMAppCredentialsProviding {
    public let credentials: any CredentialStore
    public let compiled: LastFMAppCredentials

    public init(
        credentials: any CredentialStore,
        compiled: LastFMAppCredentials = .compiled,
    ) {
        self.credentials = credentials
        self.compiled = compiled
    }

    public func appCredentials() async -> LastFMAppCredentials {
        await override()?.credentials ?? compiled
    }

    public func override() async -> LastFMAppCredentialOverride? {
        await credentials.lastFMAppCredentialOverride()
    }
}

/// Thrown while saving a pair that cannot be checked or stored.
public enum LastFMAppCredentialError: Error, Equatable, Sendable, LocalizedError {
    case incomplete
    case storage

    public var errorDescription: String? {
        switch self {
        case .incomplete:
            "Enter both the Last.fm API key and shared secret."
        case .storage:
            "The Last.fm app credentials could not be saved in the Keychain."
        }
    }
}

public extension CredentialStore {
    /// The saved override, when the one app-credential slot holds one.
    func lastFMAppCredentialOverride() async -> LastFMAppCredentialOverride? {
        guard let stored = try? await appCredential() else { return nil }
        return LastFMAppCredentialOverride(storedValue: stored)
    }

    /// Writes or clears the one app-credential slot.
    func saveLastFMAppCredentialOverride(_ override: LastFMAppCredentialOverride?) async throws {
        try await saveAppCredential(override?.storedValue)
    }
}
