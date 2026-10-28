import Foundation

/// Where service credentials live. Production is the Keychain: one item per
/// connection plus one application-credential slot. Tests and the harness use
/// ``MemoryCredentialStore``. A credential never enters the database, a log or
/// an export.
public protocol CredentialStore: Sendable {
    /// The credential for one connection, or `nil` when it has none.
    func credential(forConnection id: Int64) async throws -> String?
    /// Stores or replaces one connection's credential.
    func saveCredential(_ credential: String, forConnection id: Int64) async throws
    /// Removes one connection's credential. Unknown ids are ignored.
    func deleteCredential(forConnection id: Int64) async throws
    /// The application-owned credential, if the user supplied one.
    func appCredential() async throws -> String?
    /// Stores or clears the one application-credential slot.
    func saveAppCredential(_ credential: String?) async throws
}

/// A credential store that lives only as long as the process. Used by tests
/// and by the harness, which must never touch the real Keychain.
public actor MemoryCredentialStore: CredentialStore {
    private var credentials: [Int64: String] = [:]
    private var app: String?

    public init() {}

    public func credential(forConnection id: Int64) async throws -> String? {
        credentials[id]
    }

    public func saveCredential(_ credential: String, forConnection id: Int64) async throws {
        credentials[id] = credential
    }

    public func deleteCredential(forConnection id: Int64) async throws {
        credentials[id] = nil
    }

    public func appCredential() async throws -> String? {
        app
    }

    public func saveAppCredential(_ credential: String?) async throws {
        app = credential
    }
}
