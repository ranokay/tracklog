import Foundation
import Testing
@testable import TracklogCore

/// The composition fixture for the feedback suites, over any `ListenStore`
/// wrapper at the agreed seam.
@MainActor
func makeFeedbackRuntime(
    store: any ListenStore,
    clock: FakeClock,
    probe: HUDProbe,
    adapters: [any DeliveryAdapter] = [],
    credentials: any CredentialStore = MemoryCredentialStore(),
    source: ReplayedNowPlaying = ReplayedNowPlaying(),
) -> CaptureRuntime {
    CaptureRuntime(
        state: TracklogAppState(),
        clock: clock,
        source: source,
        store: store,
        allowlist: InMemoryAppAllowlist(),
        edits: store as? any SimpleEditStore,
        blocks: store as? any BlockStore,
        credentials: credentials,
        serviceAdapters: adapters.map { $0 as any ServiceAdapter },
        hud: probe.session,
        settings: CaptureSettings(scrobblingEnabled: true),
    )
}

/// A real store whose next feedback read can be held open, so the composition
/// tests can prove a track change or a newer local write is not overwritten by
/// a slow answer.
actor SuspendingFeedbackStore: ListenStore, FeedbackStore, ConnectionStore, DeliveryStore {
    private let base: SQLiteListenStore
    private var holdNextRead = false
    private var failNextRead = false
    private var reading = false
    private var held: [CheckedContinuation<Void, Never>] = []

    init(_ base: SQLiteListenStore) {
        self.base = base
    }

    func holdNextFeedbackRead() {
        holdNextRead = true
    }

    func failNextFeedbackRead() {
        failNextRead = true
    }

    func waitUntilReading() async {
        while !reading {
            await Task.yield()
        }
    }

    func release() {
        let waiting = held
        held.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }

    func feedback(for identities: [String]) async throws -> [String: TrackFeedback] {
        let shouldFail = failNextRead
        failNextRead = false
        if shouldFail {
            throw DatabaseError.unavailable("simulated feedback read failure")
        }
        let shouldHold = holdNextRead
        holdNextRead = false
        let loaded = try await base.feedback(for: identities)
        if shouldHold {
            reading = true
            await withCheckedContinuation { held.append($0) }
            reading = false
        }
        return loaded
    }

    func setFeedback(_ score: FeedbackScore?, for identity: String, at date: Date) async throws {
        try await base.setFeedback(score, for: identity, at: date)
    }

    func insert(_ listen: Listen) async throws -> Listen? {
        try await base.insert(listen)
    }

    func page(limit: Int, before cursor: ListenCursor?) async throws -> [Listen] {
        try await base.page(limit: limit, before: cursor)
    }

    func count() async throws -> Int {
        try await base.count()
    }

    func count(in range: Range<Date>) async throws -> Int {
        try await base.count(in: range)
    }

    func connections() async throws -> [Connection] {
        try await base.connections()
    }

    func save(_ connection: Connection) async throws -> Connection {
        try await base.save(connection)
    }

    func deleteConnection(id: Int64) async throws {
        try await base.deleteConnection(id: id)
    }

    func currentConnectionID() async throws -> Int64? {
        try await base.currentConnectionID()
    }

    func setCurrentConnectionID(_ id: Int64?) async throws {
        try await base.setCurrentConnectionID(id)
    }

    func insert(_ listen: Listen, targets: [Int64]) async throws -> Listen? {
        try await base.insert(listen, targets: targets)
    }

    func dueDeliveries(
        for connectionID: Int64,
        limit: Int,
        at date: Date,
    ) async throws -> [QueuedDelivery] {
        try await base.dueDeliveries(for: connectionID, limit: limit, at: date)
    }

    func deliveries(for listenID: Int64) async throws -> [Delivery] {
        try await base.deliveries(for: listenID)
    }

    func deliveries(forListenIDs listenIDs: [Int64]) async throws -> [Delivery] {
        try await base.deliveries(forListenIDs: listenIDs)
    }

    func pendingDeliveries() async throws -> [QueuedDelivery] {
        try await base.pendingDeliveries()
    }

    func pendingDeliveryCount(forConnection id: Int64) async throws -> Int {
        try await base.pendingDeliveryCount(forConnection: id)
    }

    func markDelivered(_ deliveryID: Int64, at date: Date, reference: String?) async throws {
        try await base.markDelivered(deliveryID, at: date, reference: reference)
    }

    func markFailed(
        _ deliveryID: Int64,
        attempts: Int,
        at date: Date,
        nextAttemptAt: Date,
        error: String,
    ) async throws {
        try await base.markFailed(
            deliveryID,
            attempts: attempts,
            at: date,
            nextAttemptAt: nextAttemptAt,
            error: error,
        )
    }

    func abandon(
        _ deliveryID: Int64,
        attempts: Int,
        lastAttemptAt: Date?,
        reason: String,
    ) async throws {
        try await base.abandon(
            deliveryID,
            attempts: attempts,
            lastAttemptAt: lastAttemptAt,
            reason: reason,
        )
    }

    func abandonPending(forConnection id: Int64, reason: String) async throws -> Int {
        try await base.abandonPending(forConnection: id, reason: reason)
    }

    func markDue(for connectionID: Int64, at date: Date) async throws {
        try await base.markDue(for: connectionID, at: date)
    }

    func earliestNextAttempt(for connectionIDs: [Int64]) async throws -> Date? {
        try await base.earliestNextAttempt(for: connectionIDs)
    }
}

/// A scripted feedback adapter for the composition suites.
@MainActor
func makeFeedbackAdapter(
    kind: ServiceKind,
    supportsLove: Bool = true,
    supportsHate: Bool = false,
    requiresReference: Bool = false,
    reference: RecordingReference? = nil,
    feedbackGate: DeliveryGate? = nil,
    lookupGate: DeliveryGate? = nil,
    feedbackAnswer: ServiceFailure? = nil,
) -> RecordingDeliveryAdapter {
    RecordingDeliveryAdapter(
        kind: kind,
        capabilities: ServiceCapabilities(
            supportsLove: supportsLove,
            supportsHate: supportsHate,
        ),
        requiresReference: requiresReference,
        reference: reference,
        lookupGate: lookupGate,
        feedbackGate: feedbackGate,
        feedbackAnswer: feedbackAnswer,
    )
}

/// Inserts one history row for a feedback action.
@MainActor
func insertHistoryListen(
    _ store: SQLiteListenStore,
    title: String = "Song",
    base: Date,
    start: TimeInterval = 0,
) async throws -> Listen {
    try #require(
        try await store.insert(
            deliveryListen(title: title, base: base, start: start),
        ),
    )
}
