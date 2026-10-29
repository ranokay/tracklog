import Foundation
import Testing
@testable import TracklogCore

@MainActor
private func feedbackHarness(
    base: Date,
    adapter: RecordingDeliveryAdapter,
) async throws -> DeliveryHarness {
    try await DeliveryHarness(base: base, adapters: [adapter])
}

private func makeBrainzAdapter(
    requiresReference: Bool = true,
    reference: RecordingReference? = .mbid("mbid-lookup"),
    lookupGate: DeliveryGate? = nil,
    feedbackGate: DeliveryGate? = nil,
    minimumRequestInterval: TimeInterval = 0,
) -> RecordingDeliveryAdapter {
    RecordingDeliveryAdapter(
        kind: .listenBrainz,
        capabilities: ServiceCapabilities(
            supportsNowPlaying: true,
            maximumBatchSize: 1,
            supportsLove: true,
            supportsHate: true,
            minimumRequestInterval: minimumRequestInterval,
        ),
        requiresReference: requiresReference,
        reference: reference,
        lookupGate: lookupGate,
        feedbackGate: feedbackGate,
    )
}

private func makeListenTrack(title: String = "Song") -> Track {
    Track(title: title, artist: "Artist", bundleID: "com.apple.Music")
}

@Suite("Feedback outbox")
@MainActor
struct FeedbackOutboxTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    @Test func historyActionUsesItsOwnReferenceAndNeverBorrowsTheCurrentTracks() async throws {
        let adapter = makeBrainzAdapter()
        let harness = try await feedbackHarness(base: base, adapter: adapter)
        let connection = try await harness.connect(kind: .listenBrainz)
        let connectionID = try #require(connection.id)
        harness.outbox.activate()

        let historyListen = try await harness.insert(
            deliveryListen(title: "History", base: base),
            for: [connection],
        )
        let delivery = try #require(try await harness.store.deliveries(for: historyListen.id ?? -1).first)
        try await harness.store.markDelivered(
            delivery.id,
            at: base,
            reference: "msid-history",
        )

        let current = Track(title: "Current", artist: "Artist", bundleID: "com.apple.Music")
        harness.outbox.sendNowPlaying(current)
        _ = await awaitNowPlaying(adapter, count: 1)

        let historyResult = await harness.outbox.sendFeedback(
            .love,
            track: historyListen.processedTrack,
            scope: .listen(historyListen.id ?? -1),
            connectionIDs: [connectionID],
        )
        #expect(historyResult.compactMap(\.id) == [connectionID])
        let historyFeedback = await adapter.feedback
        let historyLookups = await adapter.lookups
        #expect(historyFeedback.last?.reference == .msid("msid-history"))
        #expect(historyLookups.isEmpty, "a stored reference never needs a lookup")

        let currentResult = await harness.outbox.sendFeedback(
            .love,
            track: current,
            scope: .currentTrack,
            connectionIDs: [connectionID],
        )
        #expect(currentResult.compactMap(\.id) == [connectionID])
        let currentFeedback = await adapter.feedback
        #expect(currentFeedback.last?.reference == .msid("msid-1"))

        let other = Track(title: "Other", artist: "Artist", bundleID: "com.apple.Music")
        _ = await harness.outbox.sendFeedback(
            .love,
            track: other,
            scope: .currentTrack,
            connectionIDs: [connectionID],
        )
        let otherLookups = await adapter.lookups
        #expect(otherLookups.count == 1, "a different track resolves its own recording")
        let otherFeedback = await adapter.feedback
        #expect(otherFeedback.last?.reference == .mbid("mbid-lookup"))

        let noReference = try await harness.insert(
            deliveryListen(title: "No reference", base: base, start: 10),
            for: [connection],
        )
        _ = await harness.outbox.sendFeedback(
            .love,
            track: noReference.processedTrack,
            scope: .listen(noReference.id ?? -1),
            connectionIDs: [connectionID],
        )
        let noReferenceLookups = await adapter.lookups
        let noReferenceFeedback = await adapter.feedback
        #expect(noReferenceLookups.count == 2)
        #expect(
            noReferenceFeedback.last?.reference == .mbid("mbid-lookup"),
            "a history row without a reference never borrows the current track's",
        )
    }

    @Test func aDeliveredListenKeepsTheRetainedReferenceForALaterAction() async throws {
        let adapter = makeBrainzAdapter()
        let harness = try await feedbackHarness(base: base, adapter: adapter)
        let connection = try await harness.connect(kind: .listenBrainz)
        let connectionID = try #require(connection.id)
        harness.outbox.activate()

        let track = makeListenTrack()
        harness.outbox.sendNowPlaying(track)
        _ = await awaitNowPlaying(adapter, count: 1)

        let listen = try await harness.insert(
            deliveryListen(title: "Song", base: base),
            for: [connection],
        )
        harness.outbox.drain(connectionIDs: [connectionID])
        let deliveries = await awaitDeliveries(harness.store, listen: listen) {
            $0.allSatisfy { $0.state == .delivered }
        }
        #expect(deliveries.first?.serviceReference == "msid-1")

        _ = await harness.outbox.sendFeedback(
            .love,
            track: listen.processedTrack,
            scope: .listen(listen.id ?? -1),
            connectionIDs: [connectionID],
        )
        #expect(await adapter.feedback.last?.reference == .msid("msid-1"))
        #expect(await adapter.lookups.isEmpty)
    }

    @Test func lookupAndSubmissionEachKeepTheSharedSpacing() async throws {
        let adapter = makeBrainzAdapter(minimumRequestInterval: 1)
        let harness = try await feedbackHarness(base: base, adapter: adapter)
        let connection = try await harness.connect(kind: .listenBrainz)
        let connectionID = try #require(connection.id)
        harness.outbox.activate()

        let current = Track(title: "Current", artist: "Artist", bundleID: "com.apple.Music")
        harness.outbox.sendNowPlaying(current)
        _ = await awaitNowPlaying(adapter, count: 1)

        let task = Task {
            await harness.outbox.sendFeedback(
                .love,
                track: Track(title: "Other", artist: "Artist"),
                scope: .currentTrack,
                connectionIDs: [connectionID],
            )
        }

        harness.clock.advance(to: harness.clock.now.addingTimeInterval(0.5))
        await turnMainActor()
        #expect(await adapter.lookups.isEmpty)

        harness.clock.advance(to: harness.clock.now.addingTimeInterval(0.5))
        _ = await awaitLookups(adapter, count: 1)
        #expect(await adapter.feedback.isEmpty)

        harness.clock.advance(to: harness.clock.now.addingTimeInterval(0.5))
        await turnMainActor()
        #expect(await adapter.feedback.isEmpty)

        harness.clock.advance(to: harness.clock.now.addingTimeInterval(0.5))
        _ = await awaitFeedback(adapter, count: 1)
        #expect(await task.value.compactMap(\.id) == [connectionID])
    }

    @Test func cancellingWhileLookupIsSuspendedSendsNothing() async throws {
        let lookupGate = DeliveryGate()
        let adapter = makeBrainzAdapter(lookupGate: lookupGate)
        let harness = try await feedbackHarness(base: base, adapter: adapter)
        let connection = try await harness.connect(kind: .listenBrainz)
        let connectionID = try #require(connection.id)
        harness.outbox.activate()

        let task = Task {
            await harness.outbox.sendFeedback(
                .love,
                track: Track(title: "Other", artist: "Artist"),
                scope: .currentTrack,
                connectionIDs: [connectionID],
            )
        }
        await lookupGate.waitUntilEntered()
        task.cancel()
        await turnMainActor()
        await lookupGate.release()

        #expect(await task.value.isEmpty)
        await turnMainActor()
        #expect(await adapter.feedback.isEmpty)
    }

    @Test func cancellingWhileSpacingIsSuspendedSendsNothing() async throws {
        let adapter = makeBrainzAdapter(requiresReference: false, minimumRequestInterval: 1)
        let harness = try await feedbackHarness(base: base, adapter: adapter)
        let connection = try await harness.connect(kind: .listenBrainz)
        let connectionID = try #require(connection.id)
        harness.outbox.activate()

        let current = Track(title: "Current", artist: "Artist", bundleID: "com.apple.Music")
        harness.outbox.sendNowPlaying(current)
        _ = await awaitNowPlaying(adapter, count: 1)

        let task = Task {
            await harness.outbox.sendFeedback(
                .love,
                track: current,
                scope: .currentTrack,
                connectionIDs: [connectionID],
            )
        }
        harness.clock.advance(to: harness.clock.now.addingTimeInterval(0.5))
        await turnMainActor()
        #expect(await adapter.feedback.isEmpty)

        task.cancel()
        await turnMainActor()
        harness.clock.advance(to: harness.clock.now.addingTimeInterval(1))
        await turnMainActor()
        #expect(await task.value.isEmpty)
        #expect(await adapter.feedback.isEmpty)
    }

    @Test func suspendingWhileSubmissionIsInFlightDoesNotReportSuccess() async throws {
        let feedbackGate = DeliveryGate()
        let adapter = makeBrainzAdapter(
            requiresReference: false,
            feedbackGate: feedbackGate,
        )
        let harness = try await feedbackHarness(base: base, adapter: adapter)
        let connection = try await harness.connect(kind: .listenBrainz)
        let connectionID = try #require(connection.id)
        harness.outbox.activate()

        let current = Track(title: "Current", artist: "Artist", bundleID: "com.apple.Music")
        let task = Task {
            await harness.outbox.sendFeedback(
                .love,
                track: current,
                scope: .currentTrack,
                connectionIDs: [connectionID],
            )
        }
        await feedbackGate.waitUntilEntered()
        harness.outbox.suspend(connectionID: connectionID)
        await feedbackGate.release()

        #expect(await task.value.isEmpty, "a suspended connection cannot confirm a late success")
    }

    @Test func queuedLoveThenUnloveKeepsOrder() async throws {
        let feedbackGate = DeliveryGate()
        let adapter = makeBrainzAdapter(
            requiresReference: false,
            feedbackGate: feedbackGate,
        )
        let harness = try await feedbackHarness(base: base, adapter: adapter)
        let connection = try await harness.connect(kind: .listenBrainz)
        let connectionID = try #require(connection.id)
        harness.outbox.activate()

        let current = Track(title: "Current", artist: "Artist", bundleID: "com.apple.Music")
        let love = Task {
            await harness.outbox.sendFeedback(
                .love,
                track: current,
                scope: .currentTrack,
                connectionIDs: [connectionID],
            )
        }
        await feedbackGate.waitUntilEntered()
        let unlove = Task {
            await harness.outbox.sendFeedback(
                .unlove,
                track: current,
                scope: .currentTrack,
                connectionIDs: [connectionID],
            )
        }
        await turnMainActor()
        await feedbackGate.release()

        #expect(await love.value.compactMap(\.id) == [connectionID])
        #expect(await unlove.value.compactMap(\.id) == [connectionID])
        #expect(await adapter.feedback.map(\.action) == [.love, .unlove])
    }
}
