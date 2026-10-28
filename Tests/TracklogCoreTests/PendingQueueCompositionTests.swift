import Foundation
import Testing
@testable import TracklogCore

@Suite("Pending queue composition")
@MainActor
struct PendingQueueCompositionTests: CaptureTestHelpers {
    @Test func rowGlyphsAndThePendingBannerReadTheStore() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let brainz = RecordingDeliveryAdapter(kind: .listenBrainz)
        let lastFM = RecordingDeliveryAdapter(kind: .lastFM)
        let clock = FakeClock(base)
        let state = TracklogAppState()
        let runtime = makeRuntime(
            store: store,
            adapters: [brainz, lastFM],
            clock: clock,
            state: state,
        )
        await runtime.start()
        let brainzConnection = try await runtime.link(kind: .listenBrainz, credential: "token")
        let lastFMConnection = try await runtime.link(kind: .lastFM, credential: "key")
        await settleOutbox()

        let listen = try #require(
            try await store.insert(
                deliveryListen(title: "Song", base: base),
                targets: [brainzConnection.id ?? -1, lastFMConnection.id ?? -1],
            ),
        )
        let deliveries = try await store.deliveries(for: listen.id ?? -1)
        let brainzDelivery = try #require(deliveries.first { $0.connectionID == brainzConnection.id })
        let lastFMDelivery = try #require(deliveries.first { $0.connectionID == lastFMConnection.id })
        try await store.markDelivered(brainzDelivery.id, at: base, reference: nil)

        await runtime.reloadHistory()

        #expect(DeliveryAggregate(state.deliveries(for: listen)) == .pending)
        let value = DeliverySummary(state.deliveries(for: listen))
            .accessibilityValue(connections: state.connections)
        #expect(value.contains("Last.fm"))
        #expect(value.contains("ListenBrainz"))
        #expect(state.pendingQueue.count == 1)
        #expect(state.pendingQueue.groups.first?.connection.id == lastFMConnection.id)
        if case .pending = state.pendingBanner {
            // One waiting row with no special failure.
        } else {
            Issue.record("a waiting row did not raise the pending banner")
        }

        try await store.abandon(lastFMDelivery.id, attempts: 1, lastAttemptAt: base, reason: "Rejected.")
        await runtime.reloadDeliveryState()

        #expect(DeliveryAggregate(state.deliveries(for: listen)) == .notDelivered)
        #expect(state.pendingQueue.isEmpty)
        #expect(state.pendingBanner == nil)
    }

    @Test func thePendingListGroupsAcrossConnectionsAtTheCompositionSeam() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let brainz = RecordingDeliveryAdapter(kind: .listenBrainz)
        let lastFM = RecordingDeliveryAdapter(kind: .lastFM)
        let clock = FakeClock(base)
        let state = TracklogAppState()
        let runtime = makeRuntime(store: store, adapters: [brainz, lastFM], clock: clock, state: state)
        await runtime.start()
        let brainzConnection = try await runtime.link(kind: .listenBrainz, credential: "token")
        let lastFMConnection = try await runtime.link(kind: .lastFM, credential: "key")
        await settleOutbox()

        _ = try await store.insert(
            deliveryListen(title: "Newest", base: base, start: 20),
            targets: [brainzConnection.id ?? -1],
        )
        _ = try await store.insert(
            deliveryListen(title: "Oldest", base: base, start: 5),
            targets: [brainzConnection.id ?? -1],
        )
        _ = try await store.insert(
            deliveryListen(title: "Other service", base: base, start: 10),
            targets: [lastFMConnection.id ?? -1],
        )

        await runtime.reloadDeliveryState()

        #expect(
            state.pendingQueue.groups.map(\.connection.kind)
                == [.listenBrainz, .lastFM],
        )
        #expect(
            state.pendingQueue.groups.first?.items.map(\.listen.processed.title)
                == ["Oldest", "Newest"],
        )
        #expect(state.pendingQueue.count == 3)
    }

    @Test func theBannerPriorityFollowsTheLiveProblems() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let adapter = RecordingDeliveryAdapter()
        let clock = FakeClock(base)
        let state = TracklogAppState()
        let runtime = makeRuntime(store: store, adapters: [adapter], clock: clock, state: state)
        await runtime.start()
        let connection = try await runtime.link(kind: .listenBrainz, credential: "token")
        await settleOutbox()
        let id = connection.id ?? -1
        let listen = try #require(
            try await store.insert(deliveryListen(title: "Song", base: base), targets: [id]),
        )
        let delivery = try #require(try await store.deliveries(for: listen.id ?? -1).first)
        await runtime.reloadDeliveryState()
        #expect(isPending(state.pendingBanner))

        try await store.markFailed(
            delivery.id,
            attempts: 1,
            at: base,
            nextAttemptAt: base.addingTimeInterval(60),
            error: DeliveryFailure.rateLimitedMessage,
        )
        await runtime.reloadDeliveryState()
        #expect(isRateLimited(state.pendingBanner))

        var needingSignIn = connection
        needingSignIn.authState = .needsSignIn
        _ = try await store.save(needingSignIn)
        await runtime.reloadConnections()
        #expect(isNeedsSignIn(state.pendingBanner))

        state.mediaStatus = .unavailable
        #expect(state.pendingBanner == .mediaFeedUnavailable)

        state.mediaStatus = .legacyAvailable
        _ = try await store.save(connection)
        await runtime.reloadConnections()
        #expect(isRateLimited(state.pendingBanner))

        try await store.markFailed(
            delivery.id,
            attempts: 2,
            at: base,
            nextAttemptAt: base.addingTimeInterval(120),
            error: "The service could not be reached.",
        )
        await runtime.reloadDeliveryState()
        #expect(isPending(state.pendingBanner))
    }

    @Test func retryMakesAFutureConnectionDueNow() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let adapter = RecordingDeliveryAdapter()
        let clock = FakeClock(base)
        let state = TracklogAppState()
        let runtime = makeRuntime(store: store, adapters: [adapter], clock: clock, state: state)
        await runtime.start()
        let connection = try await runtime.link(kind: .listenBrainz, credential: "token")
        await settleOutbox()
        let id = connection.id ?? -1
        let listen = try #require(
            try await store.insert(deliveryListen(title: "Song", base: base), targets: [id]),
        )
        let delivery = try #require(try await store.deliveries(for: listen.id ?? -1).first)
        try await store.markFailed(
            delivery.id,
            attempts: 3,
            at: base,
            nextAttemptAt: base.addingTimeInterval(3600),
            error: "The service could not be reached.",
        )
        await runtime.reloadDeliveryState()
        #expect(state.pendingQueue.count == 1)

        runtime.retryDeliveries(forConnection: id)

        let batches = await awaitBatches(adapter, count: 1)
        #expect(batches.count == 1)
        #expect(batches.first?.first?.id == listen.id)
        await eventually { state.pendingQueue.isEmpty }
        #expect(state.pendingQueue.isEmpty)
    }

    @Test func deleteAbandonsOneDeliveryAndKeepsTheListen() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let adapter = RecordingDeliveryAdapter()
        let clock = FakeClock(base)
        let state = TracklogAppState()
        let runtime = makeRuntime(store: store, adapters: [adapter], clock: clock, state: state)
        await runtime.start()
        let connection = try await runtime.link(kind: .listenBrainz, credential: "token")
        await settleOutbox()
        let id = connection.id ?? -1
        let listen = try #require(
            try await store.insert(deliveryListen(title: "Song", base: base), targets: [id]),
        )
        await runtime.reloadHistory()
        let item = try #require(state.pendingQueue.groups.first?.items.first)

        await runtime.deleteDelivery(item.delivery)

        let updated = try #require(try await store.deliveries(for: listen.id ?? -1).first)
        #expect(updated.state == .abandoned)
        #expect(updated.abandonedReason == CaptureRuntime.deletedDeliveryReason)
        #expect(updated.lastAttemptAt == nil, "a deleted waiting row never fakes an attempt")
        #expect(state.pendingQueue.isEmpty)
        #expect(DeliveryAggregate(state.deliveries(for: listen)) == .notDelivered)
        #expect(try await store.recent(limit: 10).contains { $0.id == listen.id })
        #expect(state.listens.contains { $0.id == listen.id })
        #expect(await adapter.batches.isEmpty)
    }

    @Test func theQueueBadgeExpansionIsIndependentOfTheInlineBanner() {
        let state = TracklogAppState()
        state.mediaStatus = .unavailable
        var connection = Connection(
            id: 1,
            kind: .listenBrainz,
            endpoint: .listenBrainz,
            identity: "listener",
            createdAt: base,
        )
        connection.isEnabled = true
        state.connections = [connection]
        state.pendingQueue = PendingQueue(
            pending: [
                QueuedDelivery(
                    delivery: Delivery(
                        id: 1,
                        listenID: 1,
                        connectionID: 1,
                        state: .waiting,
                        attempts: 0,
                    ),
                    listen: listen(title: "Song", start: 0),
                ),
            ],
            connections: [connection],
        )
        state.setPendingListExpanded(true)

        #expect(state.pendingBanner == .mediaFeedUnavailable)
        #expect(state.pendingListExpanded)
        #expect(state.pendingQueue.count == 1)
    }

    private func isPending(_ banner: HistoryBanner?) -> Bool {
        if case .pending = banner {
            return true
        }
        return false
    }

    private func isRateLimited(_ banner: HistoryBanner?) -> Bool {
        if case .rateLimited = banner {
            return true
        }
        return false
    }

    private func isNeedsSignIn(_ banner: HistoryBanner?) -> Bool {
        if case .needsSignIn = banner {
            return true
        }
        return false
    }
}

@Suite("Delivery reload race")
@MainActor
struct DeliveryReloadRaceTests: CaptureTestHelpers {
    @Test func aStaleReloadCannotOverwriteANewerSnapshot() async throws {
        let database = try TemporaryDatabase()
        let sqlite = try SQLiteListenStore(url: database.url)
        let store = ControllableDeliveryStore(sqlite, failInsert: false)
        let adapter = RecordingDeliveryAdapter()
        let clock = FakeClock(base)
        let state = TracklogAppState()
        let runtime = makeRuntime(store: store, adapters: [adapter], clock: clock, state: state)
        await runtime.start()
        let connection = try await runtime.link(kind: .listenBrainz, credential: "token")
        await settleOutbox()
        await runtime.deliveryRefreshTask?.value
        let id = connection.id ?? -1

        _ = try await store.insert(deliveryListen(title: "First", base: base), targets: [id])
        await store.pauseNextPendingRead()
        let stale = Task { await runtime.reloadDeliveryState() }
        #expect(await store.waitUntilPaused())

        _ = try await store.insert(deliveryListen(title: "Second", base: base, start: 10), targets: [id])
        await runtime.reloadDeliveryState()
        #expect(state.pendingQueue.count == 2)

        await store.releasePendingRead()
        await stale.value

        #expect(state.pendingQueue.count == 2, "the older one-row snapshot must not win")
    }
}

@MainActor
private func settleOutbox() async {
    await turnMainActor(100)
}

@MainActor
private func makeRuntime(
    store: any ListenStore,
    adapters: [RecordingDeliveryAdapter],
    clock: FakeClock,
    state: TracklogAppState,
) -> CaptureRuntime {
    CaptureRuntime(
        state: state,
        clock: clock,
        source: ReplayedNowPlaying(),
        store: store,
        allowlist: InMemoryAppAllowlist(),
        credentials: MemoryCredentialStore(),
        serviceAdapters: adapters.map { $0 as any ServiceAdapter },
        settings: CaptureSettings(scrobblingEnabled: true),
    )
}
