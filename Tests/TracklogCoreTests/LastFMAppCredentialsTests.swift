import Foundation
import Testing
@testable import TracklogCore

@Suite("Last.fm app credentials")
@MainActor
struct LastFMAppCredentialsTests {
    @Test func anOverrideRoundTripsThroughTheOneAppCredentialSlot() async throws {
        let store = MemoryCredentialStore()
        let override = try #require(
            LastFMAppCredentialOverride(validating: "  key  ", sharedSecret: " secret "),
        )

        let empty = try await store.lastFMAppCredentialOverride()
        #expect(empty == nil)
        try await store.saveLastFMAppCredentialOverride(override)
        let readBack = try await store.lastFMAppCredentialOverride()
        #expect(readBack == override)
        let raw = try #require(try await store.appCredential())
        #expect(LastFMAppCredentialOverride(storedValue: raw) == override)
        #expect(override.apiKey == "key")
        #expect(override.sharedSecret == "secret")

        try await store.saveLastFMAppCredentialOverride(nil)
        let cleared = try await store.lastFMAppCredentialOverride()
        #expect(cleared == nil)
    }

    @Test func anIncompleteOrCorruptSlotIsNoOverride() async throws {
        #expect(LastFMAppCredentialOverride(validating: "  ", sharedSecret: "secret") == nil)
        #expect(LastFMAppCredentialOverride(validating: "key", sharedSecret: "\n") == nil)

        let store = MemoryCredentialStore()
        try await store.saveAppCredential("not-a-pair")
        let corrupt = try await store.lastFMAppCredentialOverride()
        #expect(corrupt == nil)
    }

    @Test func theCredentialDescriptionsNeverEchoThePair() throws {
        let credentials = LastFMAppCredentials(apiKey: "key-leak", sharedSecret: "secret-leak")
        let override = try #require(
            LastFMAppCredentialOverride(validating: "key-leak", sharedSecret: "secret-leak"),
        )

        for text in [String(describing: credentials), String(describing: override)] {
            #expect(!text.contains("key-leak"))
            #expect(!text.contains("secret-leak"))
        }
    }

    @Test func aKeychainReadFailureNeverFallsBackToTheCompiledPair() async throws {
        let transport = ScriptedTransport([])
        let adapter = LastFMAdapter(
            transport: transport,
            appCredentials: StoredLastFMAppCredentials(
                credentialStore: UnreadableAppCredentialStore(),
                compiled: lastFMTestCredentials,
            ),
        )

        await #expect(throws: LastFMError.credentialStorage) {
            _ = try await adapter.requestToken()
        }
        let requests = await transport.requests
        #expect(requests.isEmpty)
    }

    @Test func aValidOverrideTakesPrecedenceOnSignedRequests() async throws {
        let transport = ScriptedTransport([lastFMTokenResponse(), lastFMEmptyResponse()])
        let harness = try await makeHarness(transport: transport)

        try await harness.runtime.saveLastFMAppCredentialOverride(
            apiKey: "override-key",
            sharedSecret: "override-secret",
        )
        #expect(harness.state.lastFMOverridePresent)

        let firstRequest = try #require(await transport.requests.first)
        let validation = formParameters(firstRequest)
        #expect(validation["method"] == "auth.getToken")
        #expect(validation["api_key"] == "override-key")
        #expect(validation["api_sig"] == signedParameters(validation, secret: "override-secret"))

        try await link(harness)
        harness.runtime.deliveryOutbox?.sendNowPlaying(lastFMTestTrack())

        let requests = await awaitRequests(transport, count: 2)
        let lastRequest = try #require(requests.last)
        let nowPlaying = formParameters(lastRequest)
        #expect(nowPlaying["method"] == "track.updateNowPlaying")
        #expect(nowPlaying["api_key"] == "override-key")
        #expect(nowPlaying["api_sig"] == signedParameters(nowPlaying, secret: "override-secret"))
        #expect(nowPlaying["api_sig"] != signedParameters(nowPlaying, secret: lastFMTestCredentials.sharedSecret))
    }

    @Test func anInvalidOverrideFailsInlineAndChangesNothing() async throws {
        let transport = ScriptedTransport([
            lastFMErrorResponse(code: 13, message: "Invalid method signature"),
        ])
        let harness = try await makeHarness(transport: transport)
        let connection = try await link(harness)

        do {
            try await harness.runtime.saveLastFMAppCredentialOverride(
                apiKey: "bad-key",
                sharedSecret: "bad-secret",
            )
            Issue.record("expected Last.fm to reject the pair")
        } catch let failure as ServiceFailure {
            #expect(failure == .appCredentialAuth(.invalidSignature))
            #expect(failure.localizedDescription.contains("signature"))
        }

        let id = try #require(connection.id)
        #expect(try await harness.credentials.appCredential() == nil)
        #expect(harness.state.lastFMOverridePresent == false)
        #expect(harness.state.connection(id: id)?.authState == .signedIn)
        let requests = await transport.requests
        #expect(requests.count == 1)
    }

    @Test func anIncompletePairIsRefusedBeforeTheNetwork() async throws {
        let transport = ScriptedTransport([])
        let harness = try await makeHarness(transport: transport)

        await #expect(throws: LastFMAppCredentialError.incomplete) {
            try await harness.runtime.saveLastFMAppCredentialOverride(
                apiKey: "  ",
                sharedSecret: "secret",
            )
        }
        let requests = await transport.requests
        #expect(requests.isEmpty)
    }

    @Test func aSavedOverrideIsReportedAsPresenceAndNeverPublished() async throws {
        let credentials = MemoryCredentialStore()
        let override = try #require(
            LastFMAppCredentialOverride(validating: "key-leak", sharedSecret: "secret-leak"),
        )
        try await credentials.saveLastFMAppCredentialOverride(override)
        let harness = try await makeHarness(
            transport: ScriptedTransport([]),
            credentials: credentials,
        )

        #expect(harness.state.lastFMOverridePresent)
        #expect(harness.state.lastFMCompiledCredentialsPresent)
        #expect(!harness.state.lastFMNeedsAppCredentialRemedy)
        let published = String(describing: harness.state)
        #expect(!published.contains("key-leak"))
        #expect(!published.contains("secret-leak"))
    }

    @Test func removingTheOnlyPairReturnsToTheRemedyAndClearsTheSlot() async throws {
        let harness = try await makeHarness(
            transport: ScriptedTransport([lastFMTokenResponse()]),
            compiled: LastFMAppCredentials(apiKey: "", sharedSecret: ""),
        )
        try await harness.runtime.saveLastFMAppCredentialOverride(
            apiKey: "only-key",
            sharedSecret: "only-secret",
        )
        #expect(harness.state.lastFMOverridePresent)
        #expect(!harness.state.lastFMNeedsAppCredentialRemedy)

        try await harness.runtime.removeLastFMAppCredentialOverride()

        #expect(!harness.state.lastFMOverridePresent)
        #expect(harness.state.lastFMNeedsAppCredentialRemedy)
        #expect(try await harness.credentials.appCredential() == nil)
    }

    @Test func aStoredOverrideSignsRequestsAfterLaunch() async throws {
        let credentials = MemoryCredentialStore()
        let override = try #require(
            LastFMAppCredentialOverride(validating: "launch-key", sharedSecret: "launch-secret"),
        )
        try await credentials.saveLastFMAppCredentialOverride(override)
        let transport = ScriptedTransport([lastFMEmptyResponse()])
        let harness = try await makeHarness(
            transport: transport,
            credentials: credentials,
        )

        try await link(harness)
        harness.runtime.deliveryOutbox?.sendNowPlaying(lastFMTestTrack())

        let request = try #require(await awaitRequests(transport, count: 1).first)
        let params = formParameters(request)
        #expect(params["api_key"] == "launch-key")
        #expect(params["api_sig"] == signedParameters(params, secret: "launch-secret"))
    }
}
