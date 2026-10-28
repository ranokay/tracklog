import Foundation

public struct DeliveryOutboxConfiguration: Sendable {
    public var retry: DeliveryRetrySchedule

    public init(retry: DeliveryRetrySchedule = .standard) {
        self.retry = retry
    }
}

/// Drains durable deliveries, one task per connection, oldest listen first.
///
/// A trigger while a connection is draining sets a run-again flag instead of
/// starting a second drain. A batch-level failure backs off the whole batch;
/// a per-item rejection abandons one row and the drain continues. The
/// scheduler wakes at the earliest next attempt only while activated.
@MainActor
public final class DeliveryOutbox {
    public private(set) var isActive = false

    private let store: any DeliveryStore
    private let connections: ConnectionService
    private let credentials: any CredentialStore
    private let adapters: [ServiceKind: any DeliveryAdapter]
    private let clock: any Clock
    private let writer: DeliveryOutboxWriter
    private lazy var scheduler = DeliveryScheduler(
        store: store,
        clock: clock,
        eligibleConnectionIDs: { [weak self] in self?.eligibleConnectionIDs() ?? [] },
        drain: { [weak self] ids in self?.drain(connectionIDs: ids) },
    )
    private var workers: [Int64: ConnectionWorker] = [:]
    private var nowPlayingReferences: [Int64: String] = [:]
    /// The last request start per connection, kept across worker lifetimes so
    /// the one-second spacing rule survives a drain ending.
    private var lastRequestAt: [Int64: Date] = [:]

    /// The composition root publishes the connection list after an auth
    /// failure changes it.
    var onConnectionsChanged: (@MainActor () -> Void)?

    public init(
        store: any DeliveryStore,
        connections: ConnectionService,
        credentials: any CredentialStore,
        adapters: [any DeliveryAdapter],
        clock: any Clock,
        configuration: DeliveryOutboxConfiguration = DeliveryOutboxConfiguration(),
        log: @escaping @MainActor (DeliveryEvent) -> Void = { _ in },
    ) {
        self.store = store
        self.connections = connections
        self.credentials = credentials
        self.clock = clock
        writer = DeliveryOutboxWriter(
            store: store,
            clock: clock,
            retry: configuration.retry,
            log: log,
        )
        var byKind: [ServiceKind: any DeliveryAdapter] = [:]
        for adapter in adapters {
            byKind[adapter.kind] = adapter
        }
        self.adapters = byKind
    }

    // MARK: - Lifecycle

    /// Starts the activation drain and the scheduler. Calling it again while
    /// active does nothing.
    public func activate() {
        guard !isActive else { return }
        isActive = true
        drain(connectionIDs: eligibleConnectionIDs())
        scheduler.reschedule()
    }

    /// Stops every drain and the scheduler. Durable rows are untouched, so a
    /// relaunch resumes them.
    public func deactivate() {
        guard isActive else { return }
        isActive = false
        scheduler.cancel()
        workers.values.forEach { $0.task?.cancel() }
        workers.removeAll()
        lastRequestAt.removeAll()
    }

    // MARK: - Triggers

    /// Drains the given connections. A trigger during a drain makes that
    /// connection run once more instead of overlapping.
    public func drain(connectionIDs: [Int64]) {
        guard isActive else { return }
        for id in Set(connectionIDs) {
            trigger(id)
        }
    }

    /// Manual retry: makes every pending row for the connection due now and
    /// drains it. Attempts are kept, so repeated failures still reach the cap.
    public func retry(connectionID: Int64) {
        guard isActive else { return }
        Task { @MainActor [weak self] in
            guard let self, isActive else { return }
            try? await store.markDue(for: connectionID, at: clock.now)
            trigger(connectionID)
        }
    }

    /// A successful re-auth, a credential change or re-enabling a connection
    /// resumes its held rows at once rather than waiting out a backoff.
    public func resume(connectionID: Int64) {
        retry(connectionID: connectionID)
    }

    /// A fresh network path retries every connection that is eligible.
    public func networkBecameAvailable() {
        guard isActive else { return }
        Task { @MainActor [weak self] in
            guard let self, isActive else { return }
            let ids = eligibleConnectionIDs()
            for id in ids {
                try? await store.markDue(for: id, at: clock.now)
            }
            drain(connectionIDs: ids)
        }
    }

    // MARK: - Now playing

    /// Fire-and-forget to every enabled, signed-in connection that supports
    /// it. Never queued, retried or persisted.
    public func sendNowPlaying(_ track: Track) {
        guard isActive else { return }
        for connection in connections.connections where isEligible(connection) {
            guard let id = connection.id,
                  let adapter = adapters[connection.kind],
                  adapter.capabilities.supportsNowPlaying
            else { continue }
            let worker = worker(for: id)
            // Only the newest track matters; a pause between calls drops the
            // older one rather than posting it late.
            worker.nowPlaying = track
            start(worker, connectionID: id)
        }
    }

    /// The recording reference the last now playing returned, when one did.
    public func nowPlayingReference(forConnection id: Int64) -> String? {
        nowPlayingReferences[id]
    }

    // MARK: - Worker

    private func trigger(_ id: Int64) {
        let worker = worker(for: id)
        worker.drainRequested = true
        worker.runAgain = worker.task != nil
        start(worker, connectionID: id)
    }

    private func worker(for id: Int64) -> ConnectionWorker {
        if let worker = workers[id] {
            return worker
        }
        let worker = ConnectionWorker()
        workers[id] = worker
        return worker
    }

    private func start(_ worker: ConnectionWorker, connectionID id: Int64) {
        guard worker.task == nil else { return }
        worker.task = Task { @MainActor [weak self] in
            await self?.run(worker, connectionID: id)
        }
    }

    private func run(_ worker: ConnectionWorker, connectionID id: Int64) async {
        defer {
            worker.task = nil
            if workers[id] === worker {
                workers[id] = nil
            }
            if isActive {
                scheduler.reschedule()
            }
        }

        while isActive, !Task.isCancelled {
            if let track = worker.nowPlaying {
                worker.nowPlaying = nil
                await sendNowPlaying(track, connectionID: id, worker: worker)
                continue
            }

            guard worker.drainRequested else { return }
            worker.drainRequested = false
            await drainBatches(connectionID: id, worker: worker)
            if worker.runAgain {
                worker.runAgain = false
                worker.drainRequested = true
            }
        }
    }

    private func drainBatches(connectionID id: Int64, worker: ConnectionWorker) async {
        // A new now playing jumps ahead of the rest of the backlog; it is a
        // timestamped event, not a queue item.
        while isActive, !Task.isCancelled, worker.nowPlaying == nil {
            guard let connection = connection(id: id),
                  let adapter = adapters[connection.kind],
                  let credential = await credential(for: id) else { return }

            let due: [QueuedDelivery]
            do {
                due = try await store.dueDeliveries(
                    for: id,
                    limit: adapter.capabilities.maximumBatchSize,
                    at: clock.now,
                )
            } catch {
                return
            }
            guard !due.isEmpty else { return }

            await waitForSpacing(id: id, interval: adapter.capabilities.minimumRequestInterval)
            guard isActive, !Task.isCancelled else { return }
            lastRequestAt[id] = clock.now

            do {
                let results = try await adapter.submit(
                    due.map(\.listen),
                    connection: connection,
                    credential: credential,
                )
                guard results.count == due.count else { throw ServiceFailure.retryable }
                for (queued, result) in zip(due, results) {
                    await writer.apply(result, to: queued, connection: connection)
                }
            } catch {
                let failure = DeliveryFailure.from(error)
                if case .auth = failure, let connectionID = due.first?.delivery.connectionID {
                    await markNeedsSignIn(id: connectionID)
                }
                if case .rejected = failure {
                    await writer.abandon(due, connection: connection, failure: failure)
                } else {
                    await writer.backOff(due, connection: connection, failure: failure)
                }
                return
            }
        }
    }

    private func sendNowPlaying(
        _ track: Track,
        connectionID id: Int64,
        worker _: ConnectionWorker,
    ) async {
        guard let connection = connection(id: id),
              let adapter = adapters[connection.kind],
              adapter.capabilities.supportsNowPlaying,
              let credential = await credential(for: id)
        else { return }

        await waitForSpacing(id: id, interval: adapter.capabilities.minimumRequestInterval)
        guard isActive, !Task.isCancelled else { return }
        lastRequestAt[id] = clock.now

        do {
            if let reference = try await adapter.submitNowPlaying(
                track,
                connection: connection,
                credential: credential,
            ) {
                nowPlayingReferences[id] = reference
            }
        } catch let failure as ServiceFailure {
            // Now playing is never retried, but a rejected credential still
            // changes the connection so deliveries stop retrying it.
            if case .auth = failure {
                await markNeedsSignIn(id: id)
            }
            writer.log(.failed(kind: connection.kind, reason: DeliveryFailure.message(for: failure)))
        } catch {
            writer.log(.failed(kind: connection.kind, reason: DeliveryFailure.message(for: .retryable)))
        }
    }

    private func markNeedsSignIn(id: Int64) async {
        guard await (try? connections.markNeedsSignIn(id: id)) != nil else { return }
        onConnectionsChanged?()
    }

    // MARK: - Connection and credential reads

    private func connection(id: Int64) -> Connection? {
        guard let connection = connections.connections.first(where: { $0.id == id }),
              isEligible(connection)
        else { return nil }
        return connection
    }

    private func isEligible(_ connection: Connection) -> Bool {
        connection.isEnabled && connection.authState == .signedIn && adapters[connection.kind] != nil
    }

    private func eligibleConnectionIDs() -> [Int64] {
        connections.connections
            .filter(isEligible)
            .compactMap(\.id)
    }

    private func credential(for id: Int64) async -> String? {
        guard let credential = try? await credentials.credential(forConnection: id),
              !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            await markNeedsSignIn(id: id)
            return nil
        }
        return credential
    }

    private func waitForSpacing(id: Int64, interval: TimeInterval) async {
        guard interval > 0, let last = lastRequestAt[id] else { return }
        let due = last.addingTimeInterval(interval)
        guard due > clock.now else { return }
        try? await clock.sleep(until: due)
    }
}

/// One connection's in-memory work. Never holds a credential.
@MainActor
private final class ConnectionWorker {
    var task: Task<Void, Never>?
    var drainRequested = false
    var runAgain = false
    var nowPlaying: Track?
}
