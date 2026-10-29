import Foundation
import Testing
@testable import TracklogCore

/// One feedback call a scripted adapter received.
struct FeedbackRecord: Equatable, Sendable {
    let action: FeedbackAction
    let track: Track
    let reference: RecordingReference?
    let connectionID: Int64?
}

/// A delivery adapter whose answers a test scripts. Every batch is recorded
/// before the answer runs, so an overlap shows up as two recorded batches
/// while only one request was in flight. It also speaks the feedback port, so
/// the outbox and composition suites can drive fan-out without the network.
actor RecordingDeliveryAdapter: DeliveryAdapter, FeedbackAdapter {
    nonisolated let requiresReference: Bool
    enum Answer: Sendable {
        case results([DeliveryResult])
        case failure(ServiceFailure)
    }

    nonisolated let kind: ServiceKind
    nonisolated let capabilities: ServiceCapabilities
    private var answers: [Answer]
    private let gate: DeliveryGate?
    private let onSubmit: (@Sendable ([Listen]) async -> Void)?
    private(set) var batches: [[Listen]] = []
    private(set) var nowPlaying: [Track] = []
    private(set) var feedback: [FeedbackRecord] = []
    private(set) var lookups: [Track] = []
    private(set) var batchesInFlight = 0
    private(set) var peakBatchesInFlight = 0
    private let reference: RecordingReference?
    private let lookupGate: DeliveryGate?
    private let feedbackGate: DeliveryGate?
    private let feedbackAnswer: ServiceFailure?

    init(
        kind: ServiceKind = .listenBrainz,
        capabilities: ServiceCapabilities = ServiceCapabilities(
            supportsNowPlaying: true,
            maximumBatchSize: 1,
            minimumRequestInterval: 0,
        ),
        answers: [Answer] = [],
        gate: DeliveryGate? = nil,
        onSubmit: (@Sendable ([Listen]) async -> Void)? = nil,
        requiresReference: Bool = false,
        reference: RecordingReference? = nil,
        lookupGate: DeliveryGate? = nil,
        feedbackGate: DeliveryGate? = nil,
        feedbackAnswer: ServiceFailure? = nil,
    ) {
        self.kind = kind
        self.capabilities = capabilities
        self.answers = answers
        self.gate = gate
        self.onSubmit = onSubmit
        self.requiresReference = requiresReference
        self.reference = reference
        self.lookupGate = lookupGate
        self.feedbackGate = feedbackGate
        self.feedbackAnswer = feedbackAnswer
    }

    func validate(_: String, endpoint _: ServiceEndpoint) async throws -> ServiceIdentity {
        ServiceIdentity(name: "listener-\(kind.rawValue)")
    }

    func submit(
        _ listens: [Listen],
        connection _: Connection,
        credential _: String,
    ) async throws -> [DeliveryResult] {
        batches.append(listens)
        if let onSubmit {
            await onSubmit(listens)
        }
        batchesInFlight += 1
        peakBatchesInFlight = max(peakBatchesInFlight, batchesInFlight)
        if let gate {
            await gate.enter()
        }

        let answer = answers.isEmpty
            ? .results(listens.map { _ in .delivered(reference: nil) })
            : answers.removeFirst()
        do {
            let results = try resolve(answer)
            batchesInFlight -= 1
            if let gate {
                await gate.leave()
            }
            return results
        } catch {
            batchesInFlight -= 1
            if let gate {
                await gate.leave()
            }
            throw error
        }
    }

    func submitNowPlaying(
        _ track: Track,
        connection _: Connection,
        credential _: String,
    ) async throws -> String? {
        nowPlaying.append(track)
        return "msid-\(nowPlaying.count)"
    }

    func resolveReference(
        for track: Track,
        connection _: Connection,
        credential _: String,
    ) async throws -> RecordingReference? {
        lookups.append(track)
        if let lookupGate {
            await lookupGate.enter()
            await lookupGate.leave()
        }
        return reference
    }

    func submitFeedback(
        _ action: FeedbackAction,
        track: Track,
        reference: RecordingReference?,
        connection: Connection,
        credential _: String,
    ) async throws {
        feedback.append(
            FeedbackRecord(
                action: action,
                track: track,
                reference: reference,
                connectionID: connection.id,
            ),
        )
        if let feedbackGate {
            await feedbackGate.enter()
            await feedbackGate.leave()
        }
        if let feedbackAnswer {
            throw feedbackAnswer
        }
    }

    private func resolve(_ answer: Answer) throws -> [DeliveryResult] {
        switch answer {
        case let .results(results):
            results
        case let .failure(failure):
            throw failure
        }
    }
}

/// A real SQLite store, a fake clock, and one outbox for the delivery suites.
@MainActor
final class DeliveryHarness {
    let database: TemporaryDatabase
    let store: SQLiteListenStore
    let credentials: any CredentialStore
    let clock: FakeClock
    let service: ConnectionService
    let outbox: DeliveryOutbox

    init(
        base: Date = Date(timeIntervalSince1970: 1_000_000),
        adapters: [any DeliveryAdapter],
        credentials: any CredentialStore = MemoryCredentialStore(),
        retry: DeliveryRetrySchedule = DeliveryRetrySchedule(random: { 0.5 }),
    ) async throws {
        database = try TemporaryDatabase()
        store = try SQLiteListenStore(url: database.url)
        self.credentials = credentials
        clock = FakeClock(base)
        service = ConnectionService(
            store: store,
            credentials: credentials,
            adapters: adapters,
            clock: clock,
        )
        outbox = DeliveryOutbox(
            store: store,
            connections: service,
            credentials: credentials,
            adapters: adapters,
            clock: clock,
            retry: retry,
        )
    }

    @discardableResult
    func connect(
        kind: ServiceKind,
        enabled: Bool = true,
        credential: String = "token",
        identity: String? = nil,
        at date: Date? = nil,
    ) async throws -> Connection {
        let connection = try await store.save(
            Connection(
                kind: kind,
                endpoint: kind.defaultEndpoint,
                identity: identity ?? "listener-\(kind.rawValue)",
                isEnabled: enabled,
                createdAt: date ?? clock.now,
            ),
        )
        try await credentials.saveCredential(credential, forConnection: connection.id ?? -1)
        try await service.load()
        return connection
    }

    func insert(_ listen: Listen, for connections: [Connection]) async throws -> Listen {
        let targets = connections.compactMap(\.id)
        return try #require(try await store.insert(listen, targets: targets))
    }

    func deliveries(for listen: Listen) async throws -> [Delivery] {
        try await store.deliveries(for: listen.id ?? -1)
    }
}

/// A capture fixture shared by the composition suites.
@MainActor
func deliveryListen(
    title: String,
    base: Date,
    start: TimeInterval = 0,
    captured: TimeInterval = 0,
) -> Listen {
    Listen(
        raw: ListenMetadata(title: title, artist: "Artist"),
        processed: ListenMetadata(title: title, artist: "Artist"),
        bundleID: "com.apple.Music",
        duration: 200,
        playedDuration: 100,
        startedAt: base.addingTimeInterval(start),
        capturedAt: base.addingTimeInterval(captured),
    )
}

// MARK: - Async waits

@MainActor
func awaitBatches(
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
func awaitNowPlaying(
    _ adapter: RecordingDeliveryAdapter,
    count: Int,
    timeout: Duration = .seconds(3),
) async -> [Track] {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    var tracks = await adapter.nowPlaying
    while tracks.count < count, clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
        tracks = await adapter.nowPlaying
    }
    return tracks
}

@MainActor
func awaitFeedback(
    _ adapter: RecordingDeliveryAdapter,
    count: Int,
    timeout: Duration = .seconds(3),
) async -> [FeedbackRecord] {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    var records = await adapter.feedback
    while records.count < count, clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
        records = await adapter.feedback
    }
    return records
}

@MainActor
func awaitLookups(
    _ adapter: RecordingDeliveryAdapter,
    count: Int,
    timeout: Duration = .seconds(3),
) async -> [Track] {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    var tracks = await adapter.lookups
    while tracks.count < count, clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
        tracks = await adapter.lookups
    }
    return tracks
}

@MainActor
func awaitRequests(
    _ transport: ScriptedTransport,
    count: Int,
    timeout: Duration = .seconds(3),
) async -> [HTTPRequest] {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    var requests = await transport.requests
    while requests.count < count, clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
        requests = await transport.requests
    }
    return requests
}

@MainActor
func awaitDeliveries(
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
func turnMainActor(_ rounds: Int = 20) async {
    for _ in 0 ..< rounds {
        await Task.yield()
    }
}
