import Foundation
import Testing
@testable import TracklogCore

@Suite("Delivery composition")
@MainActor
struct DeliveryCompositionTests: CaptureTestHelpers {
    @Test func aCapturedListenAndItsDeliveriesAreCommittedBeforeSubmit() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let probe = SubmitProbe()
        let adapter = RecordingDeliveryAdapter(onSubmit: { listens in
            for listen in listens {
                let deliveries = try? await store.deliveries(for: listen.id ?? -1)
                await probe.record(deliveries ?? [])
            }
        })
        let clock = FakeClock(base)
        let state = TracklogAppState()
        let runtime = makeDeliveryRuntime(
            store: store,
            allowlist: InMemoryAppAllowlist(),
            credentials: MemoryCredentialStore(),
            adapters: [adapter],
            clock: clock,
            state: state,
        )
        await runtime.start()
        _ = try await runtime.link(kind: .listenBrainz, credential: "token")

        await replay(thresholdSamples(track()), on: runtime, clock: clock)

        let observed = await awaitProbe(probe, count: 1)
        #expect(observed.count == 1)
        #expect(observed.first?.count == 1)
        #expect(observed.first?.first?.state == .waiting, "the row existed before the network call")
        #expect(state.listenCount == 1)
        #expect(state.failure == nil)
    }

    @Test func aPersistFailureSendsNothing() async throws {
        let database = try TemporaryDatabase()
        let baseStore = try SQLiteListenStore(url: database.url)
        let store = ControllableDeliveryStore(baseStore)
        let adapter = RecordingDeliveryAdapter()
        let clock = FakeClock(base)
        let state = TracklogAppState()
        let runtime = makeDeliveryRuntime(
            store: store,
            allowlist: InMemoryAppAllowlist(),
            credentials: MemoryCredentialStore(),
            adapters: [adapter],
            clock: clock,
            state: state,
        )
        await runtime.start()
        _ = try await runtime.link(kind: .listenBrainz, credential: "token")

        await replay(thresholdSamples(track()), on: runtime, clock: clock)

        #expect(state.failure?.stage == .storage)
        #expect(state.listenCount == 0)
        #expect(await adapter.batches.isEmpty)
        #expect(try await baseStore.count() == 0)
    }

    @Test func onlyConnectionsEnabledAtCaptureBecomeTargets() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let listenBrainz = RecordingDeliveryAdapter(kind: .listenBrainz)
        let lastFM = RecordingDeliveryAdapter(kind: .lastFM)
        let clock = FakeClock(base)
        let state = TracklogAppState()
        let runtime = makeDeliveryRuntime(
            store: store,
            allowlist: InMemoryAppAllowlist(),
            credentials: MemoryCredentialStore(),
            adapters: [listenBrainz, lastFM],
            clock: clock,
            state: state,
        )
        await runtime.start()
        let brainz = try await runtime.link(kind: .listenBrainz, credential: "token")
        let lastFMConnection = try await runtime.link(kind: .lastFM, credential: "key")
        try await runtime.setConnectionEnabled(id: lastFMConnection.id ?? -1, enabled: false)

        await replay(thresholdSamples(track()), on: runtime, clock: clock)

        _ = await awaitBatches(listenBrainz, count: 1)
        let stored = try #require(state.listens.first)
        let deliveries = try await store.deliveries(for: stored.id ?? -1)
        #expect(deliveries.map(\.connectionID) == [brainz.id])

        try await runtime.setConnectionEnabled(id: lastFMConnection.id ?? -1, enabled: true)
        await turnMainActor()
        let afterEnable = try await store.deliveries(for: stored.id ?? -1)
        #expect(afterEnable.map(\.connectionID) == [brainz.id], "re-enabling never backfills")
        #expect(await lastFM.batches.isEmpty)
    }

    @Test func aNeedsSignInConnectionIsATargetAndHoldsItsRows() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let connection = try await store.save(
            Connection(
                kind: .listenBrainz,
                endpoint: .listenBrainz,
                identity: "listener",
                isEnabled: true,
                authState: .needsSignIn,
                createdAt: base,
            ),
        )
        try await credentials.saveCredential("token", forConnection: connection.id ?? -1)
        let adapter = RecordingDeliveryAdapter()
        let clock = FakeClock(base)
        let state = TracklogAppState()
        let runtime = makeDeliveryRuntime(
            store: store,
            allowlist: InMemoryAppAllowlist(),
            credentials: credentials,
            adapters: [adapter],
            clock: clock,
            state: state,
        )
        await runtime.start()
        #expect(state.connections.first?.authState == .needsSignIn)

        await replay(thresholdSamples(track()), on: runtime, clock: clock)

        let stored = try #require(state.listens.first)
        let deliveries = try await store.deliveries(for: stored.id ?? -1)
        #expect(deliveries.count == 1)
        #expect(deliveries.first?.connectionID == connection.id)
        #expect(deliveries.first?.state == .waiting)
        await turnMainActor()
        #expect(await adapter.batches.isEmpty, "a held row is not sent")
    }

    @Test func enablingAConnectionDrainsItsExistingRows() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let adapter = RecordingDeliveryAdapter()
        let clock = FakeClock(base)
        let state = TracklogAppState()
        let runtime = makeDeliveryRuntime(
            store: store,
            allowlist: InMemoryAppAllowlist(),
            credentials: MemoryCredentialStore(),
            adapters: [adapter],
            clock: clock,
            state: state,
        )
        await runtime.start()
        let connection = try await runtime.link(kind: .listenBrainz, credential: "token")
        try await runtime.setConnectionEnabled(id: connection.id ?? -1, enabled: false)
        let listen = try #require(
            try await store.insert(
                deliveryListen(title: "Waiting", base: base),
                targets: [connection.id ?? -1],
            ),
        )
        await turnMainActor()
        #expect(await adapter.batches.isEmpty)

        try await runtime.setConnectionEnabled(id: connection.id ?? -1, enabled: true)

        #expect(await awaitBatches(adapter, count: 1).count == 1)
        let delivered = await awaitDeliveries(store, listen: listen) {
            $0.allSatisfy { $0.state == .delivered }
        }
        #expect(delivered.map(\.state) == [.delivered])
    }

    @Test func aRelaunchDoesNotSubmitTheSameListenAgain() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let credentials = MemoryCredentialStore()
        let firstAdapter = RecordingDeliveryAdapter()
        let clock = FakeClock(base)
        let firstState = TracklogAppState()
        let first = makeDeliveryRuntime(
            store: store,
            allowlist: InMemoryAppAllowlist(),
            credentials: credentials,
            adapters: [firstAdapter],
            clock: clock,
            state: firstState,
        )
        await first.start()
        let connection = try await first.link(kind: .listenBrainz, credential: "token")
        await replay(thresholdSamples(track()), on: first, clock: clock)
        let batches = await awaitBatches(firstAdapter, count: 1)
        #expect(batches.count == 1)
        let stored = try #require(firstState.listens.first)
        first.stop()

        let secondAdapter = RecordingDeliveryAdapter()
        let secondState = TracklogAppState()
        let second = makeDeliveryRuntime(
            store: store,
            allowlist: InMemoryAppAllowlist(),
            credentials: credentials,
            adapters: [secondAdapter],
            clock: clock,
            state: secondState,
        )
        await second.start()
        await turnMainActor()

        #expect(await secondAdapter.batches.isEmpty)
        #expect(try await store.insert(stored, targets: [connection.id ?? -1]) == nil)
        #expect(try await store.deliveries(for: stored.id ?? -1).count == 1)
    }

    @Test func nowPlayingReachesListenBrainzWithTheProcessedMetadata() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let transport = ScriptedTransport([
            listenBrainzValidResponse(user: "listener"),
            HTTPResponse(
                statusCode: 200,
                body: Data(#"{"status":"ok","recording_msid":"msid-1"}"#.utf8),
            ),
        ])
        let adapter = ListenBrainzAdapter(transport: transport)
        let clock = FakeClock(base)
        let runtime = makeDeliveryRuntime(
            store: store,
            allowlist: InMemoryAppAllowlist(),
            credentials: MemoryCredentialStore(),
            adapters: [adapter],
            clock: clock,
            nowPlaying: true,
        )
        await runtime.start()
        _ = try await runtime.link(kind: .listenBrainz, credential: "token")

        let track = track(title: "Song", artist: "Artist", album: "Album")
        await replay(
            [sample(track, at: 0, elapsed: 0), sample(track, at: 2, elapsed: 2)],
            on: runtime,
            clock: clock,
        )

        let requests = await awaitRequests(transport, count: 2)
        let nowPlaying = try #require(requests.last)
        #expect(nowPlaying.url.absoluteString == "\(ServiceEndpoint.listenBrainz)/1/submit-listens?return_msid=true")
        let body = try #require(nowPlaying.body)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["listen_type"] as? String == "playing_now")
        let payload = try #require(json["payload"] as? [[String: Any]])
        let item = try #require(payload.first)
        let metadata = try #require(item["track_metadata"] as? [String: Any])
        #expect(metadata["track_name"] as? String == "Song")
        #expect(metadata["artist_name"] as? String == "Artist")
        #expect(metadata["release_name"] as? String == "Album")
    }
}

@MainActor
private func awaitProbe(_ probe: SubmitProbe, count: Int = 1) async -> [[Delivery]] {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(3)
    var observed = await probe.observed
    while observed.count < count, clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
        observed = await probe.observed
    }
    return observed
}

private actor SubmitProbe {
    private(set) var observed: [[Delivery]] = []

    func record(_ deliveries: [Delivery]) {
        observed.append(deliveries)
    }
}

@MainActor
private func makeDeliveryRuntime(
    store: any ListenStore,
    allowlist: any AppAllowlistStore,
    credentials: any CredentialStore,
    adapters: [any DeliveryAdapter],
    clock: FakeClock,
    state: TracklogAppState = TracklogAppState(),
    nowPlaying: Bool = false,
) -> CaptureRuntime {
    CaptureRuntime(
        state: state,
        clock: clock,
        source: ReplayedNowPlaying(),
        store: store,
        allowlist: allowlist,
        credentials: credentials,
        serviceAdapters: adapters.map { $0 as any ServiceAdapter },
        settings: CaptureSettings(scrobblingEnabled: true, nowPlayingEnabled: nowPlaying),
    )
}
