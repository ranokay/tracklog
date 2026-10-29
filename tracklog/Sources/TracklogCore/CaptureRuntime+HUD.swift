import Foundation

/// The activation baseline and the transition bookkeeping that keeps one HUD
/// per failure class without repeating a standing state.
struct HUDTracking {
    var primed = false
    var lastNeedsSignInIDs: Set<Int64> = []
    var lastRateLimitedIDs: Set<Int64> = []
    var notifiedStuckIDs: Set<Int64> = []
    var stuckDeliveredCounts: [Int64: Int] = [:]
    var signInRecoveries: [Int64: Int] = [:]
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
        hudTracking.notifiedStuckIDs = Set(stuckConnections().compactMap(\.id))
        hudTracking.stuckDeliveredCounts = Dictionary(
            uniqueKeysWithValues: hudTracking.notifiedStuckIDs.map { ($0, 0) },
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
        for id in stuckIDs where hudTracking.stuckDeliveredCounts[id] == nil {
            hudTracking.stuckDeliveredCounts[id] = 0
        }

        var recovered: [(Connection, Int)] = []
        for id in Array(hudTracking.stuckDeliveredCounts.keys) {
            let delivered = hudTracking.stuckDeliveredCounts[id] ?? 0
            let pending = pendingCount(forConnection: id)
            if pending == 0 {
                hudTracking.stuckDeliveredCounts[id] = nil
                if delivered > 0, let connection = state.connection(id: id) {
                    recovered.append((connection, delivered))
                }
            } else if !stuckIDs.contains(id) {
                // Paused or needs-sign-in queues are not stuck failures, and
                // an unlink removes the connection entirely.
                hudTracking.stuckDeliveredCounts[id] = nil
            }
        }

        for (connection, delivered) in recovered {
            showHUD(.caughtUp(service: connection.hudServiceName, delivered: delivered))
        }

        guard !stuckIDs.isEmpty else {
            hudTracking.notifiedStuckIDs.removeAll()
            return
        }
        guard !stuckIDs.subtracting(hudTracking.notifiedStuckIDs).isEmpty else { return }

        let count = stuck.reduce(0) { total, connection in
            total + pendingCount(forConnection: connection.id ?? -1)
        }
        showHUD(.stuckQueue(count: count, services: stuck.map(\.hudServiceName)))
        hudTracking.notifiedStuckIDs = stuckIDs
    }

    func evaluateSignedInRecoveries() {
        for id in Array(hudTracking.signInRecoveries.keys) {
            guard let delivered = hudTracking.signInRecoveries[id],
                  let connection = state.connection(id: id)
            else {
                hudTracking.signInRecoveries[id] = nil
                continue
            }
            guard pendingCount(forConnection: id) == 0 else { continue }
            hudTracking.signInRecoveries[id] = nil
            showHUD(.signedIn(service: connection.hudServiceName, delivered: delivered))
        }
    }

    func noteDelivered(connectionID: Int64) {
        if hudTracking.stuckDeliveredCounts[connectionID] != nil {
            hudTracking.stuckDeliveredCounts[connectionID, default: 0] += 1
        }
        if hudTracking.signInRecoveries[connectionID] != nil {
            hudTracking.signInRecoveries[connectionID, default: 0] += 1
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
