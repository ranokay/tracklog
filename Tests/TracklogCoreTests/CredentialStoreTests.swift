import Foundation
import Testing
@testable import TracklogCore

@Suite("Credentials")
struct CredentialStoreTests {
    @Test func perConnectionCredentialsRoundTripAndDelete() async throws {
        let store = MemoryCredentialStore()

        #expect(try await store.credential(forConnection: 1) == nil)
        try await store.saveCredential("secret-1", forConnection: 1)
        try await store.saveCredential("secret-2", forConnection: 2)
        #expect(try await store.credential(forConnection: 1) == "secret-1")
        #expect(try await store.credential(forConnection: 2) == "secret-2")

        try await store.deleteCredential(forConnection: 1)
        #expect(try await store.credential(forConnection: 1) == nil)
        #expect(try await store.credential(forConnection: 2) == "secret-2")
    }

    @Test func theOneAppCredentialSlotRoundTripsAndClears() async throws {
        let store = MemoryCredentialStore()

        #expect(try await store.appCredential() == nil)
        try await store.saveAppCredential("app-key:app-secret")
        #expect(try await store.appCredential() == "app-key:app-secret")
        try await store.saveAppCredential(nil)
        #expect(try await store.appCredential() == nil)
    }
}
