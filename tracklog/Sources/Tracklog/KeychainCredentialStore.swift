import Foundation
import Security
import TracklogCore

/// One Keychain generic-password item per connection plus one for the
/// application-owned credential. The connection's local id is the account, so
/// nothing about the service account is in the Keychain attributes.
struct KeychainCredentialStore: CredentialStore {
    private let service: String

    init(service: String = "app.tracklog.credentials") {
        self.service = service
    }

    func credential(forConnection id: Int64) async throws -> String? {
        try read(account: Self.account(for: id))
    }

    func saveCredential(_ credential: String, forConnection id: Int64) async throws {
        try write(credential, account: Self.account(for: id))
    }

    func deleteCredential(forConnection id: Int64) async throws {
        try remove(account: Self.account(for: id))
    }

    func appCredential() async throws -> String? {
        try read(account: Self.appAccount)
    }

    func saveAppCredential(_ credential: String?) async throws {
        if let credential {
            try write(credential, account: Self.appAccount)
        } else {
            try remove(account: Self.appAccount)
        }
    }

    private static let appAccount = "app"

    private static func account(for id: Int64) -> String {
        "connection-\(id)"
    }

    private func baseQuery(account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }

    private func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let credential = String(data: data, encoding: .utf8)
            else {
                throw KeychainCredentialError(status: errSecDecode)
            }
            return credential
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainCredentialError(status: status)
        }
    }

    private func write(_ credential: String, account: String) throws {
        let data = Data(credential.utf8)
        let query = baseQuery(account: account)
        let update = [kSecValueData: data] as [CFString: Any]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = query
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainCredentialError(status: addStatus)
            }
        default:
            throw KeychainCredentialError(status: status)
        }
    }

    private func remove(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialError(status: status)
        }
    }
}

struct KeychainCredentialError: Error, Equatable {
    let status: OSStatus
}
