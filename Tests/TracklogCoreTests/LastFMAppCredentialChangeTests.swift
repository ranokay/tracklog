import Foundation
import Testing
@testable import TracklogCore

@Suite("Last.fm app credential changes")
@MainActor
struct LastFMAppCredentialChangeTests {
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
        let cleared = try await harness.credentials.lastFMAppCredentialOverride()
        #expect(cleared == nil)
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

    @Test func aFailedSignOutIsRetriedBySavingAgain() async throws {
        let database = try TemporaryDatabase()
        let base = try SQLiteListenStore(url: database.url)
        let store = SignOutFailingStore(base)
        let credentials = MemoryCredentialStore()
        let transport = ScriptedTransport([lastFMTokenResponse(), lastFMTokenResponse()])
        let adapter = LastFMAdapter(
            transport: transport,
            appCredentials: StoredLastFMAppCredentials(
                credentialStore: credentials,
                compiled: lastFMTestCredentials,
            ),
        )
        let state = TracklogAppState()
        let runtime = CaptureRuntime(
            state: state,
            clock: FakeClock(lastFMAppCredentialBase),
            source: ReplayedNowPlaying(),
            store: store,
            allowlist: InMemoryAppAllowlist(),
            credentials: credentials,
            serviceAdapters: [adapter],
            compiledLastFMAppCredentials: lastFMTestCredentials,
            settings: CaptureSettings(scrobblingEnabled: false),
        )
        await runtime.start()
        let connection = try await runtime.linkVerified(
            kind: .lastFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener"),
        )
        let id = try #require(connection.id)

        do {
            try await runtime.saveLastFMAppCredentialOverride(
                apiKey: "new-key",
                sharedSecret: "new-secret",
            )
            Issue.record("expected the sign-out failure")
        } catch let error as LastFMAppCredentialError {
            #expect(error == .invalidation)
        }

        #expect(state.lastFMOverridePresent)
        // The state is published before the write, so the pending deliveries
        // are already held; only the persisted row is behind.
        #expect(state.connection(id: id)?.authState == .needsSignIn)
        let persisted = try await base.connections()
        #expect(persisted.first?.authState == .signedIn)

        // The pair is already saved; saving it again retries the pending
        // sign-out even though the effective pair did not change.
        try await runtime.saveLastFMAppCredentialOverride(
            apiKey: "new-key",
            sharedSecret: "new-secret",
        )
        #expect(state.connection(id: id)?.authState == .needsSignIn)
        let repaired = try await base.connections()
        #expect(repaired.first?.authState == .needsSignIn)
        let requests = await transport.requests
        #expect(requests.count == 2)
    }

    @Test func aPendingSignOutSurvivesRelaunchAndHoldsTheQueue() async throws {
        let database = try TemporaryDatabase()
        let base = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let transport = ScriptedTransport([lastFMTokenResponse()])
        var persistedPending: [Bool] = []
        let first = CaptureRuntime(
            state: TracklogAppState(),
            clock: FakeClock(lastFMAppCredentialBase),
            source: ReplayedNowPlaying(),
            store: SignOutFailingStore(base),
            allowlist: InMemoryAppAllowlist(),
            credentials: credentials,
            serviceAdapters: [
                LastFMAdapter(
                    transport: transport,
                    appCredentials: StoredLastFMAppCredentials(
                        credentialStore: credentials,
                        compiled: lastFMTestCredentials,
                    ),
                ),
            ],
            compiledLastFMAppCredentials: lastFMTestCredentials,
            settings: CaptureSettings(scrobblingEnabled: false),
            persistLastFMInvalidationPending: { persistedPending.append($0) },
        )
        await first.start()
        let connection = try await first.linkVerified(
            kind: .lastFM,
            credential: "session-key",
            identity: ServiceIdentity(name: "listener"),
        )
        let id = try #require(connection.id)
        let listen = try #require(
            try await base.insert(lastFMTestListen(), targets: [id]),
        )

        do {
            try await first.saveLastFMAppCredentialOverride(
                apiKey: "new-key",
                sharedSecret: "new-secret",
            )
            Issue.record("expected the sign-out failure")
        } catch let error as LastFMAppCredentialError {
            #expect(error == .invalidation)
        }
        #expect(persistedPending == [true])
        // The failed write leaves the durable row signed in under the new pair.
        #expect(try await base.connections().first?.authState == .signedIn)
        first.stop()

        let secondTransport = ScriptedTransport([])
        let second = CaptureRuntime(
            state: TracklogAppState(),
            clock: FakeClock(lastFMAppCredentialBase),
            source: ReplayedNowPlaying(),
            store: base,
            allowlist: InMemoryAppAllowlist(),
            credentials: credentials,
            serviceAdapters: [
                LastFMAdapter(
                    transport: secondTransport,
                    appCredentials: StoredLastFMAppCredentials(
                        credentialStore: credentials,
                        compiled: lastFMTestCredentials,
                    ),
                ),
            ],
            compiledLastFMAppCredentials: lastFMTestCredentials,
            settings: CaptureSettings(scrobblingEnabled: false),
            lastFMInvalidationPending: true,
            persistLastFMInvalidationPending: { persistedPending.append($0) },
        )
        await second.start()

        #expect(second.state.connection(id: id)?.authState == .needsSignIn)
        #expect(try await base.connections().first?.authState == .needsSignIn)
        #expect(persistedPending == [true, false])
        // The held row sent nothing after the relaunch.
        let requests = await secondTransport.requests
        #expect(requests.isEmpty)
        let deliveries = try await base.deliveries(for: listen.id ?? -1)
        #expect(deliveries.map(\.state) == [.waiting])
        second.stop()
    }

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

    @Test func revalidatingTheSamePairClearsAStaleProblem() async throws {
        var persisted: [AppCredentialProblem?] = []
        let credentials = MemoryCredentialStore()
        let saved = try #require(
            LastFMAppCredentialOverride(
                validating: lastFMTestCredentials.apiKey,
                sharedSecret: lastFMTestCredentials.sharedSecret,
            ),
        )
        try await credentials.saveLastFMAppCredentialOverride(saved)
        let harness = try await makeHarness(
            transport: ScriptedTransport([lastFMTokenResponse()]),
            credentials: credentials,
            appCredentialProblem: .suspendedKey,
            persistAppCredentialProblem: { persisted.append($0) },
        )

        #expect(harness.state.lastFMNeedsAppCredentialRemedy)

        // The candidate is the pair already in use, so saving it changes
        // nothing but still proves Last.fm accepts it now.
        try await harness.runtime.saveLastFMAppCredentialOverride(
            apiKey: lastFMTestCredentials.apiKey,
            sharedSecret: lastFMTestCredentials.sharedSecret,
        )

        #expect(harness.state.lastFMAppCredentialProblem == nil)
        #expect(harness.state.lastFMNeedsAppCredentialRemedy == false)
        #expect(persisted == [nil])
    }
}
