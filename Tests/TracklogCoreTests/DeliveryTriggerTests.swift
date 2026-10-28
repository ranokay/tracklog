import Foundation
import Testing
@testable import TracklogCore

@Suite("Delivery triggers")
@MainActor
struct DeliveryTriggerTests {
    private func makeHarness(
        _ adapters: [any DeliveryAdapter],
        retry: DeliveryRetrySchedule = DeliveryRetrySchedule(random: { 0.5 }),
    ) async throws -> DeliveryHarness {
        let base = Date(timeIntervalSince1970: 1_000_000)
        return try await DeliveryHarness(base: base, adapters: adapters, retry: retry)
    }

    @Test func nowPlayingFansOutToEnabledConnectionsAndIsNotQueued() async throws {
        let listenBrainz = RecordingDeliveryAdapter(kind: .listenBrainz)
        let lastFM = RecordingDeliveryAdapter(
            kind: .lastFM,
            capabilities: ServiceCapabilities(supportsNowPlaying: true),
        )
        let harness = try await makeHarness([listenBrainz, lastFM])
        let brainz = try await harness.connect(kind: .listenBrainz)
        _ = try await harness.connect(kind: .lastFM)
        harness.outbox.activate()

        let track = Track(title: "Song", artist: "Artist", album: "Album", duration: 200)
        harness.outbox.sendNowPlaying(track)

        #expect(await awaitNowPlaying(listenBrainz, count: 1) == [track])
        #expect(await awaitNowPlaying(lastFM, count: 1) == [track])
        #expect(harness.outbox.nowPlayingReference(forConnection: brainz.id ?? -1) != nil)
    }

    @Test func nowPlayingSkipsADisabledConnection() async throws {
        let listenBrainz = RecordingDeliveryAdapter(kind: .listenBrainz)
        let lastFM = RecordingDeliveryAdapter(kind: .lastFM)
        let harness = try await makeHarness([listenBrainz, lastFM])
        _ = try await harness.connect(kind: .listenBrainz)
        _ = try await harness.connect(kind: .lastFM, enabled: false)
        harness.outbox.activate()

        harness.outbox.sendNowPlaying(Track(title: "Song", artist: "Artist"))

        _ = await awaitNowPlaying(listenBrainz, count: 1)
        await turnMainActor()
        #expect(await lastFM.nowPlaying.isEmpty)
    }

    @Test func listenBrainzRequestsKeepOneSecondBetweenBatches() async throws {
        let adapter = RecordingDeliveryAdapter(
            capabilities: ServiceCapabilities(maximumBatchSize: 1, minimumRequestInterval: 1),
        )
        let harness = try await makeHarness([adapter])
        let connection = try await harness.connect(kind: .listenBrainz)
        for start in [0, 10] {
            _ = try await harness.insert(
                deliveryListen(title: "Song \(start)", base: harness.clock.now, start: TimeInterval(start)),
                for: [connection],
            )
        }

        harness.outbox.activate()
        #expect(await awaitBatches(adapter, count: 1).count == 1)

        harness.clock.advance(to: harness.clock.now.addingTimeInterval(0.5))
        await turnMainActor()
        #expect(await adapter.batches.count == 1)

        harness.clock.advance(to: harness.clock.now.addingTimeInterval(0.5))
        let batches = await awaitBatches(adapter, count: 2)
        #expect(batches.count == 2)
    }

    @Test func deactivationStopsTheScheduler() async throws {
        let adapter = RecordingDeliveryAdapter(answers: [.failure(.retryable)])
        let harness = try await makeHarness([adapter])
        let connection = try await harness.connect(kind: .listenBrainz)
        let listen = try await harness.insert(
            deliveryListen(title: "Song", base: harness.clock.now),
            for: [connection],
        )

        harness.outbox.activate()
        _ = await awaitDeliveries(harness.store, listen: listen) {
            $0.allSatisfy { $0.attempts == 1 }
        }
        harness.outbox.deactivate()

        harness.clock.advance(to: harness.clock.now.addingTimeInterval(3600))
        await turnMainActor()
        #expect(await adapter.batches.count == 1)
    }

    @Test func reactivationWaitsForAnInFlightDrainBeforeStartingAnother() async throws {
        let gate = DeliveryGate()
        let adapter = RecordingDeliveryAdapter(gate: gate)
        let harness = try await makeHarness([adapter])
        let connection = try await harness.connect(kind: .listenBrainz)
        let listen = try await harness.insert(
            deliveryListen(title: "Song", base: harness.clock.now),
            for: [connection],
        )

        harness.outbox.activate()
        await gate.waitUntilEntered()
        harness.outbox.deactivate()
        harness.outbox.activate()
        await turnMainActor()
        #expect(await adapter.batches.count == 1)

        await gate.release()
        let delivered = await awaitDeliveries(harness.store, listen: listen) {
            $0.allSatisfy { $0.state == .delivered }
        }
        #expect(delivered.map(\.state) == [.delivered])
        #expect(await adapter.peakBatchesInFlight == 1)
    }

    @Test func spacingSurvivesAFinishedDrain() async throws {
        let adapter = RecordingDeliveryAdapter(
            capabilities: ServiceCapabilities(
                supportsNowPlaying: true,
                maximumBatchSize: 1,
                minimumRequestInterval: 1,
            ),
        )
        let harness = try await makeHarness([adapter])
        let connection = try await harness.connect(kind: .listenBrainz)
        _ = try await harness.insert(
            deliveryListen(title: "Song", base: harness.clock.now),
            for: [connection],
        )

        harness.outbox.activate()
        _ = await awaitBatches(adapter, count: 1)
        harness.outbox.sendNowPlaying(Track(title: "Next", artist: "Artist"))
        harness.clock.advance(to: harness.clock.now.addingTimeInterval(0.2))
        await turnMainActor()
        #expect(await adapter.nowPlaying.isEmpty)

        harness.clock.advance(to: harness.clock.now.addingTimeInterval(0.8))
        #expect(await awaitNowPlaying(adapter, count: 1).count == 1)
    }

    @Test func networkReconnectionDrainsDueRows() async throws {
        let adapter = RecordingDeliveryAdapter(answers: [.failure(.retryable)])
        let harness = try await makeHarness([adapter])
        let connection = try await harness.connect(kind: .listenBrainz)
        let listen = try await harness.insert(
            deliveryListen(title: "Song", base: harness.clock.now),
            for: [connection],
        )

        harness.outbox.activate()
        _ = await awaitDeliveries(harness.store, listen: listen) {
            $0.allSatisfy { $0.attempts == 1 }
        }
        harness.clock.advance(to: harness.clock.now.addingTimeInterval(30))
        harness.outbox.networkBecameAvailable()

        let delivered = await awaitDeliveries(harness.store, listen: listen) {
            $0.allSatisfy { $0.state == .delivered }
        }
        #expect(delivered.map(\.state) == [.delivered])
    }

    @Test func networkReconnectionDoesNotOverrideARateLimitHint() async throws {
        let adapter = RecordingDeliveryAdapter(
            answers: [.failure(.rateLimited(retryAfter: 120))],
        )
        let harness = try await makeHarness([adapter])
        let connection = try await harness.connect(kind: .listenBrainz)
        let listen = try await harness.insert(
            deliveryListen(title: "Song", base: harness.clock.now),
            for: [connection],
        )

        harness.outbox.activate()
        _ = await awaitDeliveries(harness.store, listen: listen) {
            $0.allSatisfy { $0.attempts == 1 }
        }
        harness.outbox.networkBecameAvailable()
        await turnMainActor()
        #expect(await adapter.batches.count == 1)

        harness.clock.advance(to: harness.clock.now.addingTimeInterval(120))
        let delivered = await awaitDeliveries(harness.store, listen: listen) {
            $0.allSatisfy { $0.state == .delivered }
        }
        #expect(delivered.map(\.state) == [.delivered])
    }
}
