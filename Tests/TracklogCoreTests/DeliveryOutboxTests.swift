import Foundation
import Testing
@testable import TracklogCore

@Suite("Delivery outbox")
@MainActor
struct DeliveryOutboxTests {
    private func makeHarness(
        _ adapters: [any DeliveryAdapter],
        retry: DeliveryRetrySchedule = DeliveryRetrySchedule(random: { 0.5 }),
    ) async throws -> DeliveryHarness {
        try await DeliveryHarness(adapters: adapters, retry: retry)
    }

    @Test func activationDrainsOldestFirstAndHonoursTheBatchSize() async throws {
        let adapter = RecordingDeliveryAdapter(
            capabilities: ServiceCapabilities(maximumBatchSize: 2),
        )
        let harness = try await makeHarness([adapter])
        let connection = try await harness.connect(kind: .listenBrainz)
        let oldest = try await harness.insert(
            deliveryListen(title: "Oldest", base: harness.clock.now, start: 0),
            for: [connection],
        )
        let middle = try await harness.insert(
            deliveryListen(title: "Middle", base: harness.clock.now, start: 10),
            for: [connection],
        )
        let newest = try await harness.insert(
            deliveryListen(title: "Newest", base: harness.clock.now, start: 20),
            for: [connection],
        )

        harness.outbox.activate()

        let batches = await waitForBatches(adapter, count: 2)
        #expect(batches.map { $0.map(\.processed.title) } == [["Oldest", "Middle"], ["Newest"]])
        for listen in [oldest, middle, newest] {
            let deliveries = await waitForDeliveries(harness.store, listen: listen) {
                $0.allSatisfy { $0.state == .delivered }
            }
            #expect(deliveries.map(\.state) == [.delivered])
        }
    }

    @Test func aRetryableFailureBacksOffOneWholeBatchThenTheSchedulerRetries() async throws {
        let adapter = RecordingDeliveryAdapter(
            capabilities: ServiceCapabilities(maximumBatchSize: 2),
            answers: [.failure(.retryable)],
        )
        let harness = try await makeHarness([adapter])
        let connection = try await harness.connect(kind: .listenBrainz)
        let first = try await harness.insert(
            deliveryListen(title: "First", base: harness.clock.now, start: 0),
            for: [connection],
        )
        let second = try await harness.insert(
            deliveryListen(title: "Second", base: harness.clock.now, start: 10),
            for: [connection],
        )

        harness.outbox.activate()

        let failed = await waitForDeliveries(harness.store, listen: first) {
            $0.allSatisfy { $0.attempts == 1 }
        }
        #expect(failed.map(\.state) == [.retrying])
        #expect(failed.first?.nextAttemptAt == harness.clock.now.addingTimeInterval(30))
        let secondFailed = await waitForDeliveries(harness.store, listen: second) {
            $0.allSatisfy { $0.attempts == 1 }
        }
        #expect(secondFailed.map(\.state) == [.retrying])

        harness.clock.advance(to: harness.clock.now.addingTimeInterval(29))
        await yieldABit()
        #expect(await adapter.batches.count == 1)

        harness.clock.advance(to: harness.clock.now.addingTimeInterval(1))
        let batches = await waitForBatches(adapter, count: 2)
        #expect(batches.count == 2)
        let delivered = await waitForDeliveries(harness.store, listen: first) {
            $0.allSatisfy { $0.state == .delivered }
        }
        #expect(delivered.map(\.state) == [.delivered])
    }

    @Test func aRateLimitHintWinsOnlyWhenItIsLater() async throws {
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

        let failed = await waitForDeliveries(harness.store, listen: listen) {
            $0.allSatisfy { $0.attempts == 1 }
        }
        #expect(failed.first?.nextAttemptAt == harness.clock.now.addingTimeInterval(120))
    }

    @Test func aRejectedItemIsAbandonedAndNeverRetried() async throws {
        let adapter = RecordingDeliveryAdapter(
            answers: [.failure(.rejected("Invalid payload"))],
        )
        let harness = try await makeHarness([adapter])
        let connection = try await harness.connect(kind: .listenBrainz)
        let listen = try await harness.insert(
            deliveryListen(title: "Song", base: harness.clock.now),
            for: [connection],
        )

        harness.outbox.activate()

        let abandoned = await waitForDeliveries(harness.store, listen: listen) {
            $0.allSatisfy { $0.state == .abandoned }
        }
        #expect(abandoned.first?.abandonedReason == "Invalid payload")
        #expect(abandoned.first?.attempts == 1)

        harness.clock.advance(to: harness.clock.now.addingTimeInterval(3600))
        await yieldABit()
        #expect(await adapter.batches.count == 1)
    }

    @Test func aPerItemRejectionLeavesTheRestOfTheBatchAlone() async throws {
        let adapter = RecordingDeliveryAdapter(
            capabilities: ServiceCapabilities(maximumBatchSize: 2),
            answers: [.results([.delivered(reference: nil), .rejected(reason: "bad metadata")])],
        )
        let harness = try await makeHarness([adapter])
        let connection = try await harness.connect(kind: .listenBrainz)
        let first = try await harness.insert(
            deliveryListen(title: "First", base: harness.clock.now, start: 0),
            for: [connection],
        )
        let rejected = try await harness.insert(
            deliveryListen(title: "Rejected", base: harness.clock.now, start: 10),
            for: [connection],
        )
        let third = try await harness.insert(
            deliveryListen(title: "Third", base: harness.clock.now, start: 20),
            for: [connection],
        )

        harness.outbox.activate()

        let batches = await waitForBatches(adapter, count: 2)
        #expect(batches.map { $0.map(\.processed.title) } == [["First", "Rejected"], ["Third"]])
        let firstDelivery = try #require(try await harness.deliveries(for: first).first)
        let rejectedDelivery = try #require(try await harness.deliveries(for: rejected).first)
        let thirdDelivery = try #require(try await harness.deliveries(for: third).first)
        #expect(firstDelivery.state == .delivered)
        #expect(rejectedDelivery.state == .abandoned)
        #expect(rejectedDelivery.abandonedReason == "bad metadata")
        #expect(thirdDelivery.state == .delivered)
    }

    @Test func anAuthFailureMarksTheConnectionAndHoldsItsRows() async throws {
        let adapter = RecordingDeliveryAdapter(answers: [.failure(.auth)])
        let harness = try await makeHarness([adapter])
        let connection = try await harness.connect(kind: .listenBrainz)
        let listen = try await harness.insert(
            deliveryListen(title: "Held", base: harness.clock.now),
            for: [connection],
        )

        harness.outbox.activate()

        let failed = await waitForDeliveries(harness.store, listen: listen) {
            $0.allSatisfy { $0.attempts == 1 }
        }
        #expect(failed.first?.state == .retrying)
        #expect(harness.service.connections.first?.authState == .needsSignIn)

        let later = try await harness.insert(
            deliveryListen(title: "Later", base: harness.clock.now, start: 100),
            for: [connection],
        )
        harness.outbox.drain(connectionIDs: [connection.id ?? -1])
        await yieldABit()
        #expect(await adapter.batches.count == 1)
        #expect(try await harness.deliveries(for: later).first?.state == .waiting)
    }

    @Test func aSignedInConnectionResumesItsHeldRows() async throws {
        let adapter = RecordingDeliveryAdapter(answers: [.failure(.auth)])
        let harness = try await makeHarness([adapter])
        let connection = try await harness.connect(kind: .listenBrainz)
        let listen = try await harness.insert(
            deliveryListen(title: "Held", base: harness.clock.now),
            for: [connection],
        )

        harness.outbox.activate()
        _ = await waitForDeliveries(harness.store, listen: listen) {
            $0.allSatisfy { $0.attempts == 1 }
        }
        try await harness.service.markSignedIn(id: connection.id ?? -1)
        harness.outbox.resume(connectionID: connection.id ?? -1)

        let delivered = await waitForDeliveries(harness.store, listen: listen) {
            $0.allSatisfy { $0.state == .delivered }
        }
        #expect(delivered.map(\.state) == [.delivered])
        #expect(delivered.first?.attempts == 1, "attempts are kept across a resume")
    }

    @Test func aManualRetryMakesRowsDueWithoutResettingAttempts() async throws {
        let adapter = RecordingDeliveryAdapter(
            answers: [.failure(.retryable), .failure(.retryable)],
        )
        let harness = try await makeHarness([adapter])
        let connection = try await harness.connect(kind: .listenBrainz)
        let listen = try await harness.insert(
            deliveryListen(title: "Song", base: harness.clock.now),
            for: [connection],
        )

        harness.outbox.activate()
        let first = await waitForDeliveries(harness.store, listen: listen) {
            $0.allSatisfy { $0.attempts == 1 }
        }
        #expect(first.first?.nextAttemptAt == harness.clock.now.addingTimeInterval(30))

        harness.outbox.retry(connectionID: connection.id ?? -1)

        let second = await waitForDeliveries(harness.store, listen: listen) {
            $0.allSatisfy { $0.attempts == 2 }
        }
        #expect(second.first?.nextAttemptAt == harness.clock.now.addingTimeInterval(60))
        #expect(second.first?.state == .retrying)
    }

    @Test func aTriggerDuringADrainRunsAgainAndNeverOverlaps() async throws {
        let gate = DeliveryGate()
        let adapter = RecordingDeliveryAdapter(
            capabilities: ServiceCapabilities(maximumBatchSize: 2),
            gate: gate,
        )
        let harness = try await makeHarness([adapter])
        let connection = try await harness.connect(kind: .listenBrainz)
        for start in [0, 10, 20] {
            _ = try await harness.insert(
                deliveryListen(title: "Song \(start)", base: harness.clock.now, start: TimeInterval(start)),
                for: [connection],
            )
        }

        harness.outbox.activate()
        await gate.waitUntilEntered()
        harness.outbox.drain(connectionIDs: [connection.id ?? -1])
        await gate.release()

        let batches = await waitForBatches(adapter, count: 2)
        #expect(batches.count == 2)
        #expect(await adapter.peakBatchesInFlight == 1)
        #expect(await gate.peak == 1)
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
        _ = await waitForDeliveries(harness.store, listen: listen) {
            $0.allSatisfy { $0.attempts == 1 }
        }
        harness.outbox.deactivate()

        harness.clock.advance(to: harness.clock.now.addingTimeInterval(3600))
        await yieldABit()
        #expect(await adapter.batches.count == 1)
    }
}

// MARK: - Waits

@MainActor
private func waitForBatches(
    _ adapter: RecordingDeliveryAdapter,
    count: Int,
    timeout: Duration = .seconds(3),
) async -> [[Listen]] {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    var batches = await adapter.batches
    while batches.count < count, clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
        batches = await adapter.batches
    }
    return batches
}

@MainActor
private func waitForDeliveries(
    _ store: SQLiteListenStore,
    listen: Listen,
    timeout: Duration = .seconds(3),
    until: ([Delivery]) -> Bool,
) async -> [Delivery] {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    var deliveries = await (try? store.deliveries(for: listen.id ?? -1)) ?? []
    while !until(deliveries), clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
        deliveries = await (try? store.deliveries(for: listen.id ?? -1)) ?? []
    }
    return deliveries
}

@MainActor
private func yieldABit() async {
    for _ in 0 ..< 20 {
        await Task.yield()
    }
}
