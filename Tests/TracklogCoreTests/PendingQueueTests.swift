import Foundation
import Testing
@testable import TracklogCore

@Suite("Delivery summary")
struct DeliverySummaryTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func delivery(
        id: Int64,
        connectionID: Int64 = 1,
        state: DeliveryState,
        lastError: String? = nil,
    ) -> Delivery {
        Delivery(
            id: id,
            listenID: id,
            connectionID: connectionID,
            state: state,
            attempts: 1,
            lastError: lastError,
        )
    }

    @Test func pendingWinsAMixedRow() {
        let summary = DeliverySummary([
            delivery(id: 1, state: .delivered),
            delivery(id: 2, state: .retrying),
            delivery(id: 3, state: .abandoned),
        ])
        #expect(summary.aggregate == .pending)
    }

    @Test func anAbandonedDeliveryWithoutAPendingOneReadsNotDelivered() {
        let summary = DeliverySummary([
            delivery(id: 1, state: .delivered),
            delivery(id: 2, state: .abandoned),
        ])
        #expect(summary.aggregate == .notDelivered)
    }

    @Test func allDeliveredReadsDeliveredAndNoTargetsReadsNone() {
        #expect(DeliverySummary([delivery(id: 1, state: .delivered)]).aggregate == .delivered)
        #expect(DeliverySummary([]).aggregate == .none)
    }

    @Test func aMixedRowNamesEveryService() {
        let lastFM = Connection(
            id: 1,
            kind: .lastFM,
            endpoint: .lastFM,
            identity: "lastfm",
            createdAt: base,
        )
        let listenBrainz = Connection(
            id: 2,
            kind: .listenBrainz,
            endpoint: .listenBrainz,
            identity: "brainz",
            createdAt: base,
        )
        let summary = DeliverySummary([
            delivery(id: 1, connectionID: 1, state: .delivered),
            delivery(id: 2, connectionID: 2, state: .waiting),
        ])

        let value = summary.accessibilityValue(connections: [lastFM, listenBrainz])

        #expect(value == "delivered to Last.fm; waiting for ListenBrainz")
    }
}

@Suite("Pending queue")
struct PendingQueueTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func connection(_ id: Int64, kind: ServiceKind, needsSignIn: Bool = false) -> Connection {
        Connection(
            id: id,
            kind: kind,
            endpoint: kind.defaultEndpoint,
            identity: "listener-\(id)",
            authState: needsSignIn ? .needsSignIn : .signedIn,
            createdAt: base,
        )
    }

    private func queued(
        deliveryID: Int64,
        connectionID: Int64,
        title: String,
        start: TimeInterval,
        state: DeliveryState = .waiting,
        lastError: String? = nil,
    ) -> QueuedDelivery {
        QueuedDelivery(
            delivery: Delivery(
                id: deliveryID,
                listenID: deliveryID,
                connectionID: connectionID,
                state: state,
                attempts: 1,
                lastError: lastError,
            ),
            listen: listen(title: title, start: start),
        )
    }

    private func listen(title: String, start: TimeInterval) -> Listen {
        Listen(
            id: Int64(start) + 100,
            raw: ListenMetadata(title: title, artist: "Artist"),
            processed: ListenMetadata(title: title, artist: "Artist"),
            bundleID: "com.apple.Music",
            duration: 200,
            playedDuration: 100,
            startedAt: base.addingTimeInterval(start),
            capturedAt: base.addingTimeInterval(start),
        )
    }

    @Test func groupingFollowsConnectionOrderAndOldestListenFirst() {
        let lastFM = connection(1, kind: .lastFM)
        let brainz = connection(2, kind: .listenBrainz)
        let queue = PendingQueue(
            pending: [
                queued(deliveryID: 4, connectionID: 2, title: "Newer", start: 20),
                queued(deliveryID: 2, connectionID: 1, title: "Older", start: 10),
                queued(deliveryID: 3, connectionID: 2, title: "Older", start: 5),
            ],
            connections: [lastFM, brainz],
        )

        #expect(queue.groups.map(\.connection.id) == [1, 2])
        #expect(queue.groups.map { $0.items.map(\.delivery.id) } == [[2], [3, 4]])
        #expect(queue.count == 3)
    }

    @Test func aPausedConnectionDoesNotCountAsRateLimited() {
        let paused = connection(1, kind: .listenBrainz)
        var disabled = paused
        disabled.isEnabled = false
        let queue = PendingQueue(
            pending: [
                queued(
                    deliveryID: 1,
                    connectionID: 1,
                    title: "Song",
                    start: 0,
                    state: .retrying,
                    lastError: DeliveryFailure.rateLimitedMessage,
                ),
            ],
            connections: [disabled],
        )

        #expect(queue.rateLimitedConnections.isEmpty)
    }

    @Test func aPausedNeedsSignInConnectionDoesNotOwnTheBanner() {
        let paused = connection(1, kind: .listenBrainz, needsSignIn: true)
        var disabled = paused
        disabled.isEnabled = false
        let queue = PendingQueue(
            pending: [queued(deliveryID: 1, connectionID: 1, title: "Song", start: 0)],
            connections: [disabled],
        )

        if case .pending = HistoryBanner.resolve(
            feedAvailable: true,
            connections: [disabled],
            pending: queue,
        ) {
            // The user paused this connection, so its sign-in state is not the
            // live problem; the backlog owns the slot.
        } else {
            Issue.record("a paused needs-sign-in connection outranked the backlog")
        }
    }

    @Test func theBannerPicksTheHighestPriorityProblem() {
        let lastFM = connection(1, kind: .lastFM)
        let brainz = connection(2, kind: .listenBrainz, needsSignIn: true)
        let pending = PendingQueue(
            pending: [
                queued(
                    deliveryID: 1,
                    connectionID: 1,
                    title: "Song",
                    start: 0,
                    state: .retrying,
                    lastError: DeliveryFailure.rateLimitedMessage,
                ),
            ],
            connections: [lastFM, brainz],
        )

        #expect(
            HistoryBanner.resolve(feedAvailable: false, connections: [lastFM, brainz], pending: pending)
                == .mediaFeedUnavailable,
        )
        if case let .needsSignIn(connections) = HistoryBanner.resolve(
            feedAvailable: true,
            connections: [lastFM, brainz],
            pending: pending,
        ) {
            #expect(connections.map(\.id) == [2])
        } else {
            Issue.record("needs sign-in did not outrank rate limiting")
        }
        if case let .rateLimited(connections) = HistoryBanner.resolve(
            feedAvailable: true,
            connections: [lastFM, connection(2, kind: .listenBrainz)],
            pending: pending,
        ) {
            #expect(connections.map(\.id) == [1])
        } else {
            Issue.record("rate limiting did not outrank the backlog")
        }
        if case .pending = HistoryBanner.resolve(
            feedAvailable: true,
            connections: [lastFM],
            pending: PendingQueue(
                pending: [queued(deliveryID: 9, connectionID: 1, title: "Song", start: 0)],
                connections: [lastFM],
            ),
        ) {
            // The backlog owns the slot once the rate-limit row clears.
        } else {
            Issue.record("the pending backlog did not own the slot")
        }
        #expect(
            HistoryBanner.resolve(
                feedAvailable: true,
                connections: [lastFM],
                pending: PendingQueue(),
            ) == nil,
        )
    }
}
