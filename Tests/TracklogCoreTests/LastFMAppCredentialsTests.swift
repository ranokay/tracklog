import Foundation
import Testing
@testable import TracklogCore

private struct Harness {
    let database: TemporaryDatabase
    let store: SQLiteListenStore
    let credentials: MemoryCredentialStore
    let transport: ScriptedTransport
    let state: TracklogAppState
    let runtime: CaptureRuntime
}

@Suite("Last.fm app credentials")
@MainActor
struct LastFMAppCredentialsTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func makeHarness(
        transport: ScriptedTransport,
        credentials: MemoryCredentialStore = MemoryCredentialStore(),
        compiled: LastFMAppCredentials = lastFMTestCredentials,
        appCredentialProblem: AppCredentialProblem? = nil,
        persistAppCredentialProblem: (@MainActor (AppCredentialProblem?) -> Void)? = nil,
    ) async throws -> Harness {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let clock = FakeClock(base)
        let state = TracklogAppState()
        let adapter = LastFMAdapter(
            transport: transport,
            appCredentials: StoredLastFMAppCredentials(
                credentials: credentials,
                compiled: compiled,
            ),
        )
        let runtime = CaptureRuntime(
            state: state,
            clock: clock,
            source: ReplayedNowPlaying(),
            store: store,
            allowlist: InMemoryAppAllowlist(),
            credentials: credentials,
            serviceAdapters: [adapter],
            compiledLastFMAppCredentials: compiled,
            settings: CaptureSettings(scrobblingEnabled: false),
            appCredentialProblem: appCredentialProblem,
            persistAppCredentialProblem: persistAppCredentialProblem,
        )
        await runtime.start()
        return Harness(
            database: database,
            store: store,
            credentials: credentials,
            transport: transport,
            state: state,
            runtime: runtime,
        )
    }

    @discardableResult
    private func link(_ harness: Harness, credential: String = "session-key") async throws -> Connection {
        try await harness.runtime.linkVerified(
            kind: .lastFM,
            credential: credential,
            identity: ServiceIdentity(name: "listener"),
        )
    }

    // MARK: - The stored pair

    @Test func anOverrideRoundTripsThroughTheOneAppCredentialSlot() async throws {
        let store = MemoryCredentialStore()
        let override = try #require(
            LastFMAppCredentialOverride(validating: "  key  ", sharedSecret: " secret "),
        )

        let empty = await store.lastFMAppCredentialOverride()
        #expect(empty == nil)
        try await store.saveLastFMAppCredentialOverride(override)
        let readBack = await store.lastFMAppCredentialOverride()
        #expect(readBack == override)
        let raw = try #require(try await store.appCredential())
        #expect(LastFMAppCredentialOverride(storedValue: raw) == override)
        #expect(override.apiKey == "key")
        #expect(override.sharedSecret == "secret")

        try await store.saveLastFMAppCredentialOverride(nil)
        let cleared = await store.lastFMAppCredentialOverride()
        #expect(cleared == nil)
    }

    @Test func anIncompleteOrCorruptSlotIsNoOverride() async throws {
        #expect(LastFMAppCredentialOverride(validating: "  ", sharedSecret: "secret") == nil)
        #expect(LastFMAppCredentialOverride(validating: "key", sharedSecret: "\n") == nil)

        let store = MemoryCredentialStore()
        try await store.saveAppCredential("not-a-pair")
        let corrupt = await store.lastFMAppCredentialOverride()
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

    // MARK: - Precedence and validation

    @Test func aValidOverrideTakesPrecedenceOnSignedRequests() async throws {
        let transport = ScriptedTransport([lastFMTokenResponse(), lastFMEmptyResponse()])
        let harness = try await makeHarness(transport: transport)

        try await harness.runtime.saveLastFMAppCredentialOverride(
            apiKey: "override-key",
            sharedSecret: "override-secret",
        )
        #expect(harness.state.lastFMOverridePresent)
        let effectiveKey = await harness.runtime.effectiveLastFMAppCredentials()?.apiKey
        #expect(effectiveKey == "override-key")

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
        let effective = await harness.runtime.effectiveLastFMAppCredentials()
        #expect(effective == lastFMTestCredentials)
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

    // MARK: - Changing the pair

    @Test func changingThePairSignsEveryLastFMConnectionOutAndHoldsItsDeliveries() async throws {
        let transport = ScriptedTransport([lastFMTokenResponse()])
        let harness = try await makeHarness(transport: transport)
        let connection = try await link(harness)
        // The link triggers a drain that has no rows yet. Let it finish before
        // inserting, so the only request after the save is the one under test.
        await turnMainActor(100)
        let id = try #require(connection.id)
        let listen = try #require(
            try await harness.store.insert(lastFMTestListen(), targets: [id]),
        )

        try await harness.runtime.saveLastFMAppCredentialOverride(
            apiKey: "new-key",
            sharedSecret: "new-secret",
        )

        #expect(harness.state.connection(id: id)?.authState == .needsSignIn)
        #expect(harness.state.connections.allSatisfy { $0.authState == .needsSignIn })
        #expect(harness.state.pendingCount == 1)

        harness.runtime.deliveryOutbox?.drain(connectionIDs: [id])
        await turnMainActor()

        let deliveries = try await harness.store.deliveries(for: listen.id ?? -1)
        #expect(deliveries.map(\.state) == [.waiting])
        #expect(deliveries.map(\.attempts) == [0])
        // The only request is the validation call; the held delivery sent none.
        let requests = await transport.requests
        #expect(requests.count == 1)
        let firstRequest = try #require(requests.first)
        let held = formParameters(firstRequest)
        #expect(held["method"] == "auth.getToken")
    }

    @Test func removingTheOverrideSignsTheSignedInConnectionOut() async throws {
        let transport = ScriptedTransport([lastFMTokenResponse()])
        let harness = try await makeHarness(transport: transport)

        // Save before linking: no connection exists yet, so nothing is signed
        // out by the save itself.
        try await harness.runtime.saveLastFMAppCredentialOverride(
            apiKey: "override-key",
            sharedSecret: "override-secret",
        )
        let connection = try await link(harness)
        let id = try #require(connection.id)
        #expect(harness.state.connection(id: id)?.authState == .signedIn)

        try await harness.runtime.removeLastFMAppCredentialOverride()

        #expect(harness.state.lastFMOverridePresent == false)
        #expect(harness.state.connection(id: id)?.authState == .needsSignIn)
        let effective = await harness.runtime.effectiveLastFMAppCredentials()
        #expect(effective == lastFMTestCredentials)
    }

    @Test func removingAnAbsentOverrideDoesNotSignAnyoneOut() async throws {
        let transport = ScriptedTransport([])
        let harness = try await makeHarness(transport: transport)
        let connection = try await link(harness)
        let id = try #require(connection.id)

        try await harness.runtime.removeLastFMAppCredentialOverride()

        #expect(harness.state.connection(id: id)?.authState == .signedIn)
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

    // MARK: - The remedy state

    @Test func aMissingCompiledPairPointsAtTheOverridePage() async throws {
        let harness = try await makeHarness(
            transport: ScriptedTransport([]),
            compiled: LastFMAppCredentials(apiKey: "", sharedSecret: ""),
        )

        #expect(harness.state.lastFMCompiledCredentialsPresent == false)
        #expect(harness.state.lastFMAppCredentialsAvailable == false)
        #expect(harness.state.lastFMNeedsAppCredentialRemedy)
    }

    @Test func aRejectedCompiledPairPointsAtTheOverridePageUntilItIsReplaced() async throws {
        var persisted: [AppCredentialProblem?] = []
        let transport = ScriptedTransport([lastFMTokenResponse()])
        let harness = try await makeHarness(
            transport: transport,
            appCredentialProblem: .invalidKey,
            persistAppCredentialProblem: { persisted.append($0) },
        )

        #expect(harness.state.lastFMNeedsAppCredentialRemedy)

        try await harness.runtime.saveLastFMAppCredentialOverride(
            apiKey: "working-key",
            sharedSecret: "working-secret",
        )

        #expect(harness.state.lastFMAppCredentialProblem == nil)
        #expect(harness.state.lastFMNeedsAppCredentialRemedy == false)
        #expect(persisted == [nil])
    }
}
