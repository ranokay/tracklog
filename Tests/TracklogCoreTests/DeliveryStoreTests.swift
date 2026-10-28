import Foundation
import Testing
@testable import TracklogCore

@Suite("Delivery store")
struct DeliveryStoreTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func listen(
        title: String = "Song",
        start: TimeInterval = 0,
        captured: TimeInterval? = nil,
    ) -> Listen {
        Listen(
            raw: ListenMetadata(title: title, artist: "Artist"),
            processed: ListenMetadata(title: title, artist: "Artist"),
            bundleID: "com.apple.Music",
            duration: 200,
            playedDuration: 100,
            startedAt: base.addingTimeInterval(start),
            capturedAt: base.addingTimeInterval(captured ?? start),
        )
    }

    private func connection(_ store: SQLiteListenStore, identity: String = "listener") async throws -> Connection {
        try await store.save(
            Connection(
                kind: .listenBrainz,
                endpoint: .listenBrainz,
                identity: identity,
                createdAt: base,
            ),
        )
    }

    @Test func aListenAndItsDeliveriesAreStoredTogether() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let first = try await connection(store, identity: "first")

        let stored = try #require(
            try await store.insert(listen(title: "One"), targets: [first.id ?? -1]),
        )
        let deliveries = try await store.deliveries(for: stored.id ?? -1)

        #expect(deliveries.count == 1)
        #expect(deliveries.first?.listenID == stored.id)
        #expect(deliveries.first?.connectionID == first.id)
        #expect(deliveries.first?.state == .waiting)
        #expect(deliveries.first?.attempts == 0)
        #expect(deliveries.first?.nextAttemptAt == base)
    }

    @Test func zeroTargetsStoresTheListenWithoutDeliveries() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)

        let stored = try #require(try await store.insert(listen(), targets: []))
        let deliveries = try await store.deliveries(for: stored.id ?? -1)

        #expect(deliveries.isEmpty)
        #expect(try await store.recent(limit: 1) == [stored])
    }

    @Test func aDuplicateListenWritesNoDeliveryRows() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let first = try await connection(store)

        let stored = try #require(
            try await store.insert(listen(), targets: [first.id ?? -1]),
        )
        let duplicate = try await store.insert(listen(), targets: [first.id ?? -1])

        #expect(stored.id != nil)
        #expect(duplicate == nil)
        #expect(try await store.deliveries(for: stored.id ?? -1).count == 1)
        #expect(try await store.count() == 1)
    }

    @Test func anUnknownTargetRollsBackTheWholeWrite() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)

        await #expect(throws: (any Error).self) {
            _ = try await store.insert(listen(), targets: [999])
        }

        #expect(try await store.count() == 0)
    }

    @Test func dueDeliveriesAreOldestListenFirst() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let target = try await connection(store)
        let id = target.id ?? -1

        let newest = try #require(try await store.insert(listen(title: "Newest", start: 300), targets: [id]))
        let oldest = try #require(try await store.insert(listen(title: "Oldest", start: 100), targets: [id]))
        let middle = try #require(try await store.insert(listen(title: "Middle", start: 200), targets: [id]))

        let due = try await store.dueDeliveries(for: id, limit: 10, at: base.addingTimeInterval(500))

        #expect(due.map(\.listen.id) == [oldest.id, middle.id, newest.id])
        #expect(due.allSatisfy { $0.delivery.state == .waiting })
    }

    @Test func onlyRowsAtOrBeforeTheDateAreDue() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let target = try await connection(store)
        let id = target.id ?? -1
        _ = try await store.insert(listen(start: 10), targets: [id])
        let first = try await store.dueDeliveries(for: id, limit: 10, at: base.addingTimeInterval(10))
        let delivery = try #require(first.first)

        try await store.markFailed(
            delivery.delivery.id,
            attempts: 1,
            at: base.addingTimeInterval(10),
            nextAttemptAt: base.addingTimeInterval(40),
            error: "offline",
        )

        #expect(try await store.dueDeliveries(for: id, limit: 10, at: base.addingTimeInterval(39)).isEmpty)
        let later = try await store.dueDeliveries(for: id, limit: 10, at: base.addingTimeInterval(40))
        #expect(later.first?.delivery.attempts == 1)
        #expect(later.first?.delivery.state == .retrying)
        #expect(later.first?.delivery.lastError == "offline")
    }

    @Test func markDeliveredRemovesTheRowFromTheDueSet() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let target = try await connection(store)
        let id = target.id ?? -1
        let stored = try #require(try await store.insert(listen(), targets: [id]))
        let delivery = try #require(try await store.deliveries(for: stored.id ?? -1).first)

        try await store.markDelivered(
            delivery.id,
            at: base.addingTimeInterval(5),
            reference: "msid-1",
        )

        let updated = try #require(try await store.deliveries(for: stored.id ?? -1).first)
        #expect(updated.state == .delivered)
        #expect(updated.deliveredAt == base.addingTimeInterval(5))
        #expect(updated.serviceReference == "msid-1")
        #expect(updated.nextAttemptAt == nil)
        #expect(try await store.dueDeliveries(for: id, limit: 10, at: base.addingTimeInterval(99)).isEmpty)
    }

    @Test func abandonmentKeepsTheReasonAndTheListen() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let target = try await connection(store)
        let id = target.id ?? -1
        let stored = try #require(try await store.insert(listen(), targets: [id]))
        let delivery = try #require(try await store.deliveries(for: stored.id ?? -1).first)

        try await store.abandon(delivery.id, attempts: 1, at: base, reason: "The service rejected it.")

        let updated = try #require(try await store.deliveries(for: stored.id ?? -1).first)
        #expect(updated.state == .abandoned)
        #expect(updated.abandonedReason == "The service rejected it.")
        #expect(updated.lastError == "The service rejected it.")
        #expect(try await store.recent(limit: 1).count == 1)
    }

    @Test func markingDueMovesPendingRowsWithoutTouchingAttempts() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let target = try await connection(store)
        let id = target.id ?? -1
        let stored = try #require(try await store.insert(listen(), targets: [id]))
        let delivery = try #require(try await store.deliveries(for: stored.id ?? -1).first)
        try await store.markFailed(
            delivery.id,
            attempts: 3,
            at: base,
            nextAttemptAt: base.addingTimeInterval(3600),
            error: "offline",
        )

        try await store.markDue(for: id, at: base.addingTimeInterval(10))

        let updated = try #require(try await store.deliveries(for: stored.id ?? -1).first)
        #expect(updated.nextAttemptAt == base.addingTimeInterval(10))
        #expect(updated.attempts == 3)
        #expect(updated.state == .retrying)
        #expect(try await store.dueDeliveries(for: id, limit: 10, at: base.addingTimeInterval(10)).count == 1)
    }

    @Test func theEarliestNextAttemptOnlyCountsPendingDeliveries() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let target = try await connection(store)
        let id = target.id ?? -1
        let early = try #require(try await store.insert(listen(start: 0), targets: [id]))
        let late = try #require(try await store.insert(listen(start: 10), targets: [id]))
        let earlyDelivery = try #require(try await store.deliveries(for: early.id ?? -1).first)
        let lateDelivery = try #require(try await store.deliveries(for: late.id ?? -1).first)
        try await store.markFailed(
            earlyDelivery.id,
            attempts: 1,
            at: base,
            nextAttemptAt: base.addingTimeInterval(30),
            error: "offline",
        )
        try await store.markFailed(
            lateDelivery.id,
            attempts: 1,
            at: base,
            nextAttemptAt: base.addingTimeInterval(60),
            error: "offline",
        )

        #expect(try await store.earliestNextAttempt(for: [id]) == base.addingTimeInterval(30))
        try await store.markDelivered(earlyDelivery.id, at: base, reference: nil)
        #expect(try await store.earliestNextAttempt(for: [id]) == base.addingTimeInterval(60))
        #expect(try await store.earliestNextAttempt(for: []) == nil)
    }
}
