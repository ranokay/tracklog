import Foundation

/// Drains durable deliveries, one task per connection, oldest listen first.
///
/// A trigger while a connection is draining sets a run-again flag instead of
/// starting a second drain. A batch-level failure backs off the whole batch;
/// a per-item rejection abandons one row and the drain continues. The
/// scheduler wakes at the earliest next attempt only while activated.
@MainActor
public final class DeliveryOutbox {
    public private(set) var isActive = false

    let store: any DeliveryStore
    let lookup: DeliveryConnectionLookup
    let feedbackAdapters: [ServiceKind: any FeedbackAdapter]
    let clock: any Clock
    let writer: DeliveryOutboxWriter
    private lazy var scheduler = DeliveryScheduler(
        store: store,
        clock: clock,
        eligibleConnectionIDs: { [weak self] in self?.lookup.eligibleConnectionIDs() ?? [] },
        drain: { [weak self] ids in self?.drain(connectionIDs: ids) },
    )
    var workers: [Int64: ConnectionWorker] = [:]
    /// The recording reference the last now playing returned, per connection.
    var nowPlayingReferences: [Int64: String] = [:]
    /// The track that reference belongs to. A later action may use it only for
    /// the same track, never for another listen or the current track's neighbour.
    var nowPlayingReferenceTracks: [Int64: String] = [:]
    /// The last request start per connection, kept across worker lifetimes so
    /// the one-second spacing rule survives a drain ending.
    var lastRequestAt: [Int64: Date] = [:]
    /// A local write failed; do not resend the batch while the store is sick.
    var blockedUntil: [Int64: Date] = [:]
    /// Connections held while a credential or identity operation runs. Their
    /// workers may still be finishing a cancellation; a new drain must wait.
    var suspended: Set<Int64> = []

    /// The composition root publishes the connection list after an auth
    /// failure changes it.
    var onConnectionsChanged: (@MainActor () -> Void)?
    /// Called when a drain ends and the durable delivery rows may have moved.
    var onDeliveryStateChanged: (@MainActor () -> Void)?
    /// The service rejected the application's own credentials. The Services
    /// page shows the reason; this is not a per-account sign-in problem.
    var onAppCredentialProblem: (@MainActor (ServiceKind, AppCredentialProblem) -> Void)?
    /// One item reached its service, so a stale app-credential warning can
    /// clear and a recovery HUD can count what was actually delivered.
    var onDeliverySucceeded: (@MainActor (ServiceKind, Int64) -> Void)?

    public init(
        store: any DeliveryStore,
        connections: ConnectionService,
        credentials: any CredentialStore,
        adapters: [any DeliveryAdapter],
        feedbackAdapters: [any FeedbackAdapter]? = nil,
        clock: any Clock,
        retry: DeliveryRetrySchedule = .standard,
        log: @escaping @MainActor (DeliveryEvent) -> Void = { _ in
            // The outbox is silent until the composition root supplies a log.
        },
    ) {
        self.store = store
        lookup = DeliveryConnectionLookup(
            connections: connections,
            credentials: credentials,
            adapters: adapters,
        )
        var feedbackByKind: [ServiceKind: any FeedbackAdapter] = [:]
        for adapter in feedbackAdapters ?? adapters.compactMap({ $0 as? any FeedbackAdapter }) {
            feedbackByKind[adapter.kind] = adapter
        }
        self.feedbackAdapters = feedbackByKind
        self.clock = clock
        writer = DeliveryOutboxWriter(
            store: store,
            clock: clock,
            retry: retry,
            log: log,
        )
    }

    // MARK: - Lifecycle

    /// Starts the activation drain and the scheduler. Calling it again while
    /// active does nothing.
    public func activate() {
        guard !isActive else { return }
        isActive = true
        suspended.removeAll()
        drain(connectionIDs: lookup.eligibleConnectionIDs())
        scheduler.reschedule()
    }

    /// Stops every drain and the scheduler. Durable rows are untouched, so a
    /// relaunch resumes them.
    public func deactivate() {
        guard isActive else { return }
        isActive = false
        scheduler.cancel()
        workers.values.forEach { $0.stop() }
        lastRequestAt.removeAll()
    }

    // MARK: - Triggers

    /// Drains the given connections. A trigger during a drain makes that
    /// connection run once more instead of overlapping.
    public func drain(connectionIDs: [Int64]) {
        guard isActive else { return }
        Set(connectionIDs).forEach(trigger)
    }

    /// Stops one connection's worker without touching its durable rows, for an
    /// operation that is about to change its credential or identity. The
    /// worker stays registered until its cancelled task ends, so a later
    /// trigger cannot start a second drain beside it.
    public func suspend(connectionID id: Int64) {
        suspended.insert(id)
        stopWorker(id)
        clearRecordingReference(id: id)
        if isActive {
            scheduler.reschedule()
        }
    }

    /// Stops one connection's worker after its row is gone.
    public func connectionRemoved(connectionID id: Int64) {
        suspended.remove(id)
        stopWorker(id)
        clearRecordingReference(id: id)
        lastRequestAt[id] = nil
        blockedUntil[id] = nil
        if isActive {
            scheduler.reschedule()
        }
    }

    /// A successful re-auth, a credential change or re-enabling a connection
    /// drains whatever is already due; a manual retry is the way to make a
    /// backed-off row due now.
    public func resume(connectionID: Int64) {
        suspended.remove(connectionID)
        drain(connectionIDs: [connectionID])
    }

    /// A fresh network path drains whatever is already due. It never rewrites
    /// a backoff or a rate-limit hint; only a manual retry does that.
    public func networkBecameAvailable() {
        guard isActive else { return }
        Task { @MainActor [weak self] in
            guard let self, isActive else { return }
            drain(connectionIDs: lookup.eligibleConnectionIDs())
        }
    }

    // MARK: - Now playing

    /// Fire-and-forget to every enabled, signed-in connection that supports
    /// it. Never queued, retried or persisted.
    public func sendNowPlaying(_ track: Track) {
        guard isActive else { return }
        for connection in lookup.connections.connections where lookup.isEligible(connection) {
            guard let id = connection.id, !suspended.contains(id),
                  let adapter = lookup.adapters[connection.kind],
                  adapter.capabilities.supportsNowPlaying
            else { continue }
            let worker = worker(for: id)
            // Only the newest track matters; a pause between calls drops the
            // older one rather than posting it late.
            worker.nowPlaying = track
            start(worker, connectionID: id)
        }
    }

    // MARK: - Worker

    private func trigger(_ id: Int64) {
        guard !suspended.contains(id) else { return }
        let worker = worker(for: id)
        worker.drainRequested = true
        worker.runAgain = worker.task != nil
        start(worker, connectionID: id)
    }

    /// Cancels a worker without dropping its entry while the task is still
    /// running. The task's own defer removes it when it ends.
    private func stopWorker(_ id: Int64) {
        guard let worker = workers[id] else { return }
        if worker.task == nil {
            workers[id] = nil
        } else {
            worker.stop()
        }
    }

    func worker(for id: Int64) -> ConnectionWorker {
        if let worker = workers[id] {
            return worker
        }
        let worker = ConnectionWorker()
        workers[id] = worker
        return worker
    }

    func start(_ worker: ConnectionWorker, connectionID id: Int64) {
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
            // A reactivation that arrived while this cancelled task was still
            // in flight must wait for it, so two drains never overlap.
            if isActive {
                if worker.drainRequested {
                    trigger(id)
                } else {
                    scheduler.reschedule()
                }
                onDeliveryStateChanged?()
            }
        }

        while isActive, !Task.isCancelled {
            if !worker.feedback.isEmpty {
                let pending = worker.feedback.removeFirst()
                guard !pending.isCancelled else {
                    pending.resume(nil)
                    continue
                }
                let connection = await performFeedback(pending, connectionID: id)
                pending.resume(connection)
                continue
            }

            if let track = worker.nowPlaying {
                worker.nowPlaying = nil
                await sendNowPlaying(track, connectionID: id)
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
        while isActive, !Task.isCancelled, worker.nowPlaying == nil, worker.feedback.isEmpty {
            guard await drainOnce(connectionID: id, worker: worker) else { return }
        }
    }

    /// Returns true when another batch may be due.
    private func drainOnce(connectionID id: Int64, worker _: ConnectionWorker) async -> Bool {
        guard blockedUntil[id].map({ $0 <= clock.now }) ?? true,
              let connection = lookup.connection(id: id),
              let adapter = lookup.adapters[connection.kind],
              let due = await dueDeliveries(for: id, limit: adapter.capabilities.maximumBatchSize),
              !due.isEmpty,
              let token = await token(for: id, due: due, connection: connection)
        else { return false }

        await waitForSpacing(id: id, interval: adapter.capabilities.minimumRequestInterval)
        guard isActive, !Task.isCancelled else { return false }
        lastRequestAt[id] = clock.now

        do {
            let results = try await adapter.submit(
                due.map(\.listen),
                connection: connection,
                credential: token,
            )
            guard results.count == due.count else { throw ServiceFailure.retryable }
            let outcome = await apply(results, to: due, connection: connection)
            if !outcome.persisted {
                blockedUntil[id] = clock.now.addingTimeInterval(30)
            }
            return outcome.continueDraining
        } catch {
            if let problem = DeliveryFailure.from(error).appCredentialProblem {
                onAppCredentialProblem?(connection.kind, problem)
            }
            let outcome = await writer.handleFailure(
                error,
                due: due,
                connection: connection,
                markNeedsSignIn: { [weak self] id in await self?.markNeedsSignIn(id: id) },
            )
            if !outcome.persisted {
                blockedUntil[id] = clock.now.addingTimeInterval(30)
            }
            return outcome.continueDraining
        }
    }

    private func dueDeliveries(for id: Int64, limit: Int) async -> [QueuedDelivery]? {
        do {
            return try await store.dueDeliveries(for: id, limit: limit, at: clock.now)
        } catch {
            return nil
        }
    }

    private func token(for id: Int64, due: [QueuedDelivery], connection: Connection) async -> String? {
        switch await lookup.credential(for: id) {
        case let .value(stored):
            return stored
        case .missing:
            await markNeedsSignIn(id: id)
            return nil
        case .unavailable:
            // A local read failure is not a rejected credential. Keep the
            // connection signed in and let the normal backoff retry it.
            let persisted = await writer.backOff(due, connection: connection, failure: .retryable)
            if !persisted {
                blockedUntil[id] = clock.now.addingTimeInterval(30)
            }
            return nil
        }
    }
}
