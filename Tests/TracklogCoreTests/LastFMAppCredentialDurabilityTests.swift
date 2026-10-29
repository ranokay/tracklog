import Foundation
import Testing
@testable import TracklogCore

@Suite("Last.fm app credential durability")
@MainActor
struct LastFMAppCredentialDurabilityTests {
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

    @Test func aFailedCredentialWriteKeepsTheInvalidationMarker() async throws {
        var persistedPending: [Bool] = []
        let credentials = SaveFailingAppCredentialStore()
        let transport = ScriptedTransport([lastFMTokenResponse()])
        let runtime = CaptureRuntime(
            state: TracklogAppState(),
            clock: FakeClock(lastFMAppCredentialBase),
            source: ReplayedNowPlaying(),
            store: nil,
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
        await runtime.start()

        await #expect(throws: LastFMAppCredentialError.storage) {
            try await runtime.saveLastFMAppCredentialOverride(
                apiKey: "new-key",
                sharedSecret: "new-secret",
            )
        }
        // The obligation is durable even though the credential write failed.
        #expect(persistedPending == [true])
    }
}
