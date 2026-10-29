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
actor SuspendingFeedbackStore: ListenStore, FeedbackStore, ConnectionStore {
    private let base: SQLiteListenStore
    private var holdNextRead = false
    private var reading = false
    private var held: [CheckedContinuation<Void, Never>] = []

    init(_ base: SQLiteListenStore) {
        self.base = base
    }

    func holdNextFeedbackRead() {
        holdNextRead = true
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
) async throws -> Listen {
    try #require(try await store.insert(deliveryListen(title: title, base: base)))
}
