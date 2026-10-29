import Foundation
import Testing
@testable import TracklogCore

@Suite("HUD composition")
@MainActor
struct HUDCompositionTests: CaptureTestHelpers {
    @Test func needsSignInFailuresAggregateIntoOneCard() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let lastFM = RecordingDeliveryAdapter(kind: .lastFM, answers: [.failure(.auth)])
        let brainz = RecordingDeliveryAdapter(kind: .listenBrainz, answers: [.failure(.auth)])
        let lastFMConnection = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .lastFM,
            base: base,
        )
        let brainzConnection = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .listenBrainz,
            identity: "listener-listenbrainz",
            base: base,
        )
        let runtime = makeHUDRuntime(
            store: store,
            clock: clock,
            probe: probe,
            adapters: [lastFM, brainz],
            credentials: credentials,
        )
        await runtime.start()
        await turnMainActor(100)
        _ = try await insertHUDPending(
            store,
            connection: lastFMConnection,
            title: "One",
            base: base,
        )
        _ = try await insertHUDPending(
            store,
            connection: brainzConnection,
            title: "Two",
            base: base,
        )

        runtime.retryDeliveries(forConnection: lastFMConnection.id ?? -1)
        await eventually { probe.presentations.count == 1 }

        let first = try #require(probe.presentations.first)
        #expect(first.id == "hud.failure.signin")
        #expect(first.title == "Last.fm needs sign-in")
        #expect(first.action == .signIn)
        #expect(probe.announcements == ["Last.fm needs sign-in. Scrobbles are waiting."])

        runtime.retryDeliveries(forConnection: brainzConnection.id ?? -1)
        await eventually { probe.presentations.count == 2 }

        let second = try #require(probe.presentations.last)
        #expect(second.title == "2 services need sign-in")
        #expect(second.spoken == "Last.fm and ListenBrainz need sign-in. Scrobbles are waiting.")
        #expect(second.action == .signIn)
        #expect(probe.announcements.last == second.spoken)

        await runtime.reloadConnections()
        await runtime.reloadDeliveryState()
        #expect(probe.presentations.count == 2, "a standing failure is not repeated")
    }

    @Test func rateLimitFailuresAggregateAndRecoveryStaysSilent() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let lastFM = RecordingDeliveryAdapter(
            kind: .lastFM,
            answers: [
                .failure(.rateLimited(retryAfter: 120)),
                .results([.delivered(reference: nil)]),
            ],
        )
        let brainz = RecordingDeliveryAdapter(
            kind: .listenBrainz,
            answers: [.failure(.rateLimited(retryAfter: 120))],
        )
        let lastFMConnection = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .lastFM,
            base: base,
        )
        let brainzConnection = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .listenBrainz,
            identity: "listener-listenbrainz",
            base: base,
        )
        let runtime = makeHUDRuntime(
            store: store,
            clock: clock,
            probe: probe,
            adapters: [lastFM, brainz],
            credentials: credentials,
        )
        await runtime.start()
        await turnMainActor(100)
        let lastFMListen = try await insertHUDPending(
            store,
            connection: lastFMConnection,
            title: "One",
            base: base,
        )
        _ = try await insertHUDPending(
            store,
            connection: brainzConnection,
            title: "Two",
            base: base,
        )

        runtime.retryDeliveries(forConnection: lastFMConnection.id ?? -1)
        await eventually { probe.presentations.count == 1 }
        #expect(probe.presentations.first?.id == "hud.failure.ratelimit")
        #expect(probe.presentations.first?.spoken == "Last.fm is rate limited. Retrying automatically.")

        runtime.retryDeliveries(forConnection: brainzConnection.id ?? -1)
        await eventually { probe.presentations.count == 2 }
        #expect(probe.presentations.last?.spoken == "2 services are rate limited. Retrying automatically.")

        runtime.retryDeliveries(forConnection: lastFMConnection.id ?? -1)
        _ = await awaitDeliveries(store, listen: lastFMListen) {
            $0.allSatisfy { $0.state == .delivered }
        }
        await turnMainActor(100)
        #expect(probe.presentations.count == 2, "rate-limit recovery is silent")
    }

    @Test func mediaFeedFailureRaisesOnceAndRecoveryStaysSilent() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let source = ReplayedNowPlaying()
        let runtime = makeHUDRuntime(
            store: store,
            clock: clock,
            probe: probe,
            adapters: [],
            credentials: MemoryCredentialStore(),
            source: source,
        )
        await runtime.start()

        source.emitStatus(.unavailable)
        await eventually { probe.presentations.count == 1 }
        #expect(probe.presentations.first?.id == "hud.failure.media")
        #expect(probe.presentations.first?.word == "No feed")
        #expect(probe.presentations.first?.spoken == "Media feed unavailable. Playback will not be scrobbled.")

        source.emitStatus(.legacyAvailable)
        await turnMainActor(20)
        #expect(probe.presentations.count == 1, "media recovery is silent")
    }

    @Test func preExistingRateLimitAndSignInStatesAreSilentAtActivation() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let lastFM = RecordingDeliveryAdapter(kind: .lastFM)
        let brainz = RecordingDeliveryAdapter(kind: .listenBrainz)
        let lastFMConnection = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .lastFM,
            base: base,
        )
        let brainzConnection = try await saveHUDConnection(
            store,
            credentials: credentials,
            kind: .listenBrainz,
            identity: "listener-listenbrainz",
            base: base,
            authState: .needsSignIn,
        )
        let rateLimitedListen = try #require(
            try await store.insert(
                deliveryListen(title: "Rate limited", base: base),
                targets: [lastFMConnection.id ?? -1],
            ),
        )
        let rateLimitedDelivery = try #require(
            try await store.deliveries(for: rateLimitedListen.id ?? -1).first,
        )
        try await store.markFailed(
            rateLimitedDelivery.id,
            attempts: 1,
            at: base,
            nextAttemptAt: base.addingTimeInterval(10 * 24 * 60 * 60),
            error: DeliveryFailure.rateLimitedMessage,
        )
        _ = try await insertHUDPending(
            store,
            connection: brainzConnection,
            title: "Signed out",
            base: base,
        )

        let runtime = makeHUDRuntime(
            store: store,
            clock: clock,
            probe: probe,
            adapters: [lastFM, brainz],
            credentials: credentials,
        )
        await runtime.start()

        #expect(probe.presentations.isEmpty)
        #expect(probe.announcements.isEmpty)

        await runtime.reloadDeliveryState()
        #expect(probe.presentations.isEmpty, "standing failures stay silent")
    }

    @Test func aPreExistingMediaFailureAtActivationIsSilent() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let clock = FakeClock(base)
        let probe = HUDProbe()
        let source = ReplayedNowPlaying()
        source.mediaStatus = .unavailable
        let runtime = makeHUDRuntime(
            store: store,
            clock: clock,
            probe: probe,
            adapters: [],
            credentials: MemoryCredentialStore(),
            source: source,
        )
        await runtime.start()

        #expect(probe.presentations.isEmpty)
        #expect(probe.announcements.isEmpty)
    }
}
