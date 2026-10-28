import Foundation
import Testing
@testable import TracklogCore

@Suite("Last.fm outbox")
@MainActor
struct LastFMOutboxTests {
    private func makeHarness(_ adapters: [any DeliveryAdapter]) async throws -> DeliveryHarness {
        try await DeliveryHarness(adapters: adapters)
    }

    @Test func aPerItemRateLimitBacksOffOnlyThatItemAndStopsTheDrain() async throws {
        let adapter = RecordingDeliveryAdapter(
            kind: .lastFM,
            capabilities: ServiceCapabilities(maximumBatchSize: 2),
            answers: [
                .results([.delivered(reference: nil), .rateLimited(retryAfter: 120)]),
            ],
        )
        let harness = try await makeHarness([adapter])
        let connection = try await harness.connect(kind: .lastFM)
        let first = try await harness.insert(
            deliveryListen(title: "First", base: harness.clock.now, start: 0),
            for: [connection],
        )
        let limited = try await harness.insert(
            deliveryListen(title: "Limited", base: harness.clock.now, start: 10),
            for: [connection],
        )
        let waiting = try await harness.insert(
            deliveryListen(title: "Waiting", base: harness.clock.now, start: 20),
            for: [connection],
        )

        harness.outbox.activate()

        let delivered = await awaitDeliveries(harness.store, listen: first) {
            $0.allSatisfy { $0.state == .delivered }
        }
        #expect(delivered.map(\.state) == [.delivered])
        let limitedDelivery = try #require(try await harness.deliveries(for: limited).first)
        #expect(limitedDelivery.state == .retrying)
        #expect(limitedDelivery.attempts == 1)
        #expect(limitedDelivery.nextAttemptAt == harness.clock.now.addingTimeInterval(120))
        #expect(limitedDelivery.lastError == DeliveryFailure.rateLimitedMessage)
        let waitingDelivery = try #require(try await harness.deliveries(for: waiting).first)
        #expect(waitingDelivery.state == .waiting)
        #expect(await adapter.batches.count == 1, "a daily limit stops the next batch")
    }

    @Test func anAppCredentialRejectionMarksTheConnectionAndReportsTheReason() async throws {
        let adapter = RecordingDeliveryAdapter(
            kind: .lastFM,
            answers: [.failure(.appCredentialAuth(.suspendedKey))],
        )
        let harness = try await makeHarness([adapter])
        let connection = try await harness.connect(kind: .lastFM)
        let listen = try await harness.insert(
            deliveryListen(title: "Held", base: harness.clock.now),
            for: [connection],
        )
        var reported: [(ServiceKind, AppCredentialProblem)] = []
        harness.outbox.onAppCredentialProblem = { kind, problem in
            reported.append((kind, problem))
        }

        harness.outbox.activate()

        _ = await awaitDeliveries(harness.store, listen: listen) {
            $0.allSatisfy { $0.attempts == 1 }
        }
        #expect(harness.service.connections.first?.authState == .needsSignIn)
        #expect(reported.count == 1)
        #expect(reported.first?.0 == .lastFM)
        #expect(reported.first?.1 == .suspendedKey)
        #expect(try await harness.deliveries(for: listen).first?.state == .retrying)
    }
}
