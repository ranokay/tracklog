import Foundation
import Testing
@testable import TracklogCore

@Suite("Feedback worker")
@MainActor
struct FeedbackWorkerTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    @Test func feedbackRateLimitCoolsDownNowPlayingAndDeliveries() async throws {
        let adapter = makeBrainzAdapter(
            requiresReference: false,
            feedbackAnswer: .rateLimited(retryAfter: 120),
        )
        let harness = try await feedbackHarness(base: base, adapter: adapter)
        let connection = try await harness.connect(kind: .listenBrainz)
        let connectionID = try #require(connection.id)
        harness.outbox.activate()

        let current = Track(title: "Current", artist: "Artist", bundleID: "com.apple.Music")
        let feedback = await harness.outbox.sendFeedback(
            .love,
            track: current,
            scope: .currentTrack,
            connectionIDs: [connectionID],
        )
        #expect(feedback.isEmpty)
        #expect(await adapter.feedback.count == 1)

        harness.outbox.sendNowPlaying(current)
        let listen = try await harness.insert(
            deliveryListen(title: "Song", base: harness.clock.now),
            for: [connection],
        )
        harness.outbox.drain(connectionIDs: [connectionID])
        await turnMainActor(50)
        #expect(await adapter.nowPlaying.isEmpty)
        #expect(await adapter.batches.isEmpty)

        harness.clock.advance(to: harness.clock.now.addingTimeInterval(120))
        harness.outbox.sendNowPlaying(current)
        harness.outbox.drain(connectionIDs: [connectionID])
        #expect(await awaitNowPlaying(adapter, count: 1).count == 1)
        #expect(await awaitBatches(adapter, count: 1).count == 1)
        let delivered = await awaitDeliveries(harness.store, listen: listen) {
            $0.allSatisfy { $0.state == .delivered }
        }
        #expect(delivered.allSatisfy { $0.state == .delivered })
    }

    @Test func reactivationResumesFeedbackQueuedOnTheCancelledWorker() async throws {
        let gate = DeliveryGate()
        let adapter = makeBrainzAdapter(requiresReference: false, feedbackGate: gate)
        let harness = try await feedbackHarness(base: base, adapter: adapter)
        let connection = try await harness.connect(kind: .listenBrainz)
        let connectionID = try #require(connection.id)
        harness.outbox.activate()

        let current = Track(title: "Current", artist: "Artist", bundleID: "com.apple.Music")
        let first = Task {
            await harness.outbox.sendFeedback(
                .love,
                track: current,
                scope: .currentTrack,
                connectionIDs: [connectionID],
            )
        }
        await gate.waitUntilEntered()
        harness.outbox.deactivate()
        harness.outbox.activate()

        var secondFinished = false
        var secondResult: [Connection] = []
        let second = Task {
            secondResult = await harness.outbox.sendFeedback(
                .unlove,
                track: current,
                scope: .currentTrack,
                connectionIDs: [connectionID],
            )
            secondFinished = true
        }
        await turnMainActor()
        await gate.release()
        _ = await first.value
        await turnMainActor(100)

        #expect(secondFinished, "feedback queued on a cancelled worker must be resumed")
        #expect(secondResult.isEmpty)
        #expect(await adapter.feedback.count == 1)
        #expect(await adapter.feedback.first?.action == .love)
        second.cancel()
    }
}
