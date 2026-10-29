import Foundation

/// The activation baseline and the transition bookkeeping that keeps one HUD
/// per failure class without repeating a standing state.
struct HUDTracking {
    var primed = false
    var lastNeedsSignInIDs: Set<Int64> = []
    var lastRateLimitedIDs: Set<Int64> = []
    var notifiedStuckSets: Set<Set<Int64>> = []
    var stuckRecoveries: [Int64: StuckRecovery] = [:]
    var signInRecoveries: [Int64: SignInRecovery] = [:]
}

/// One stuck queue the runtime is counting deliveries for, tied to the
/// identity it belonged to.
struct StuckRecovery: Equatable {
    let identity: String
    var delivered: Int
}

/// One re-auth attempt that may still produce a recovery strip. The identity
/// is part of the record so a replacement account can never inherit it.
struct SignInRecovery: Equatable {
    let identity: String
    var delivered: Int
}

// MARK: - HUD state

extension CaptureRuntime {
    static let stuckDeliveryInterval: TimeInterval = 24 * 60 * 60

    /// Records every standing failure before activation drains anything. The
    /// widget and banner carry that state; a launch never raises a HUD for it.
    func primeHUDBaselines() {
        hudTracking.primed = true
        hudTracking.lastNeedsSignInIDs = needsSignInIDs()
        hudTracking.lastRateLimitedIDs = rateLimitedIDs()
        hudTracking.notifiedStuckSets.removeAll()
        let baselineStuck = stuckConnections()
        let baselineStuckIDs = Set(baselineStuck.compactMap(\.id))
        if !baselineStuckIDs.isEmpty {
            hudTracking.notifiedStuckSets.insert(baselineStuckIDs)
        }
        hudTracking.stuckRecoveries = Dictionary(
            uniqueKeysWithValues: baselineStuck.compactMap { connection in
                connection.id.map {
                    ($0, StuckRecovery(identity: connection.identity, delivered: 0))
                }
            },
        )
        hudTracking.signInRecoveries.removeAll()
    }

    /// A sign-in required for an enabled connection aggregates into one card.
    /// A pre-existing set is silent; adding a connection to it presents the
    /// current set once.
    func evaluateSignInHUD() {
        guard hudTracking.primed else { return }
        let current = needsSignInIDs()
        let added = current.subtracting(hudTracking.lastNeedsSignInIDs)
        hudTracking.lastNeedsSignInIDs = current
        guard !added.isEmpty else { return }

        let services = state.connections
            .filter { $0.id.map(current.contains) ?? false }
            .map(\.hudServiceName)
        showHUD(.needsSignIn(services: services))
    }

    /// Total media loss is a failure strip; regaining a source is silent.
    func evaluateMediaHUD(wasAvailable: Bool, isAvailable: Bool) {
        guard hudTracking.primed, wasAvailable, !isAvailable else { return }
        showHUD(.mediaFeedUnavailable)
    }

    /// Rate-limit transitions, stuck-set transitions and the two recovery
    /// classes. Ordinary drain success never reaches here.
    func evaluateDeliveryHUD() {
        guard hudTracking.primed else { return }
        evaluateRateLimitHUD()
        evaluateStuckHUD()
        evaluateSignedInRecoveries()
    }

    func evaluateRateLimitHUD() {
        let current = rateLimitedIDs()
        let added = current.subtracting(hudTracking.lastRateLimitedIDs)
        hudTracking.lastRateLimitedIDs = current
        guard !added.isEmpty else { return }

        let services = state.pendingQueue.rateLimitedConnections.map(\.hudServiceName)
        showHUD(.rateLimited(services: services))
    }

    /// Presents one card for a new stuck connection set and one caught-up
    /// strip per connection whose stuck queue drained. The delivered count is
    /// counted from actual delivery successes, never from pending-row drops.
    func evaluateStuckHUD() {
        let stuck = stuckConnections()
        let stuckIDs = Set(stuck.compactMap(\.id))

        var recovered: [(Connection, Int)] = []
        for id in Array(hudTracking.stuckRecoveries.keys) {
            guard let record = hudTracking.stuckRecoveries[id] else { continue }
            let pending = pendingCount(forConnection: id)
            let connection = state.connection(id: id)
            let current = connection?.identity == record.identity
                && connection?.isEnabled == true
                && connection?.authState == .signedIn
            if pending == 0 {
                hudTracking.stuckRecoveries[id] = nil
                if record.delivered > 0, let connection, current {
                    recovered.append((connection, record.delivered))
                }
            } else if !current {
                // A paused or signed-out queue is not a stuck failure. An
                // unlink removes the connection, and a different identity
                // replaces it without inheriting the old count.
                hudTracking.stuckRecoveries[id] = nil
            }
        }
        for connection in stuck {
            guard let id = connection.id, hudTracking.stuckRecoveries[id] == nil else { continue }
            hudTracking.stuckRecoveries[id] = StuckRecovery(
                identity: connection.identity,
                delivered: 0,
            )
        }

        for (connection, delivered) in recovered {
            showHUD(.caughtUp(service: connection.hudServiceName, delivered: delivered))
        }

        guard !stuckIDs.isEmpty, !hudTracking.notifiedStuckSets.contains(stuckIDs) else { return }

        let count = stuck.reduce(0) { total, connection in
            total + pendingCount(forConnection: connection.id ?? -1)
        }
        showHUD(.stuckQueue(count: count, services: stuck.map(\.hudServiceName)))
        hudTracking.notifiedStuckSets.insert(stuckIDs)
    }

    func evaluateSignedInRecoveries() {
        for id in Array(hudTracking.signInRecoveries.keys) {
            guard let recovery = hudTracking.signInRecoveries[id],
                  let connection = state.connection(id: id),
                  connection.identity == recovery.identity,
                  connection.isEnabled,
                  connection.authState == .signedIn
            else {
                hudTracking.signInRecoveries[id] = nil
                continue
            }
            guard pendingCount(forConnection: id) == 0 else { continue }
            hudTracking.signInRecoveries[id] = nil
            showHUD(.signedIn(service: connection.hudServiceName, delivered: recovery.delivered))
        }
    }

    /// A new auth failure, a pause, an unlink or an account replacement makes
    /// the in-flight re-auth recovery stale.
    func invalidateSignInRecoveries() {
        for id in Array(hudTracking.signInRecoveries.keys) {
            guard let recovery = hudTracking.signInRecoveries[id],
                  let connection = state.connection(id: id),
                  connection.identity == recovery.identity,
                  connection.isEnabled,
                  connection.authState == .signedIn
            else {
                hudTracking.signInRecoveries[id] = nil
                continue
            }
        }
    }

    func noteDelivered(connectionID: Int64) {
        if let record = hudTracking.stuckRecoveries[connectionID],
           let connection = state.connection(id: connectionID),
           connection.identity == record.identity,
           connection.authState == .signedIn {
            hudTracking.stuckRecoveries[connectionID]?.delivered += 1
        }
        if let recovery = hudTracking.signInRecoveries[connectionID],
           let connection = state.connection(id: connectionID),
           connection.identity == recovery.identity,
           connection.authState == .signedIn {
            hudTracking.signInRecoveries[connectionID]?.delivered += 1
        }
    }

    func showHUD(_ event: HUDEvent) {
        hudSession?.show(HUD.resolve(event))
    }
}

// MARK: - Stuck timing

extension CaptureRuntime {
    /// Enabled, signed-in connections whose oldest pending delivery is
    /// strictly older than 24 hours.
    func stuckConnections() -> [Connection] {
        let groups = Dictionary(
            uniqueKeysWithValues: state.pendingQueue.groups.compactMap { group in
                group.connection.id.map { ($0, group) }
            },
        )
        return state.connections.filter { connection in
            guard connection.isEnabled, connection.authState == .signedIn,
                  let id = connection.id,
                  let oldest = groups[id]?.items.first
            else { return false }
            return clock.now.timeIntervalSince(oldest.listen.startedAt) > Self.stuckDeliveryInterval
        }
    }

    /// Schedules the next threshold that is still in the future. Connections
    /// already in a stuck set are excluded, so a past deadline is never
    /// rescheduled and a standing failure cannot spin the runtime.
    func scheduleStuckEvaluation() {
        stuckEvaluationTask?.cancel()
        stuckEvaluationTask = nil
        guard started, hudTracking.primed, hudSession != nil,
              let deadline = nextStuckDeadline()
        else { return }

        let generation = startGeneration
        stuckEvaluationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard !Task.isCancelled, started, hudTracking.primed, generation == startGeneration else {
                return
            }
            stuckEvaluationTask = nil
            await reloadDeliveryState()
        }
    }

    private func nextStuckDeadline() -> Date? {
        let stuckIDs = Set(stuckConnections().compactMap(\.id))
        var earliest: Date?
        for group in state.pendingQueue.groups {
            guard let id = group.connection.id, !stuckIDs.contains(id),
                  group.connection.isEnabled, group.connection.authState == .signedIn,
                  let oldest = group.items.first
            else { continue }

            let deadline = oldest.listen.startedAt
                .addingTimeInterval(Self.stuckDeliveryInterval + 1)
            guard deadline > clock.now else { continue }
            if earliest == nil || deadline < earliest! {
                earliest = deadline
            }
        }
        return earliest
    }

    func pendingCount(forConnection id: Int64) -> Int {
        state.pendingQueue.groups.first { $0.connection.id == id }?.items.count ?? 0
    }

    func needsSignInIDs() -> Set<Int64> {
        Set(
            state.connections
                .filter { $0.isEnabled && $0.authState == .needsSignIn }
                .compactMap(\.id),
        )
    }

    func rateLimitedIDs() -> Set<Int64> {
        Set(state.pendingQueue.rateLimitedConnections.compactMap(\.id))
    }
}
