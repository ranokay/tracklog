import Foundation

/// The decision after one batch-level failure.
struct DeliveryFailureOutcome {
    let continueDraining: Bool
    /// False when the local rows could not record the outcome.
    let persisted: Bool
}

/// Applies one batch's outcomes and one batch's backoff. Kept apart from the
/// drain loop so the loop reads as scheduling rather than bookkeeping.
@MainActor
struct DeliveryOutboxWriter {
    let store: any DeliveryStore
    let clock: any Clock
    let retry: DeliveryRetrySchedule
    let log: @MainActor (DeliveryEvent) -> Void

    /// Returns whether the local state write landed. A failed write stops the
    /// drain so the same batch is not resubmitted in a tight loop.
    func apply(_ result: DeliveryResult, to queued: QueuedDelivery, connection: Connection) async -> Bool {
        switch result {
        case let .delivered(reference):
            do {
                try await store.markDelivered(
                    queued.delivery.id,
                    at: clock.now,
                    reference: reference,
                )
                log(.delivered(kind: connection.kind, count: 1))
                return true
            } catch {
                return false
            }
        case let .rejected(message):
            return await abandon(queued, reason: DeliveryFailure.message(for: .rejected(message)), kind: connection.kind)
        case let .rateLimited(retryAfter):
            return await backOff(
                [queued],
                connection: connection,
                failure: .rateLimited(retryAfter: retryAfter),
            )
        }
    }

    /// Decides one batch-level failure and reports whether the drain should
    /// continue and whether the local rows recorded the outcome.
    func handleFailure(
        _ error: any Error,
        due: [QueuedDelivery],
        connection: Connection,
        markNeedsSignIn: @MainActor (Int64) async -> Void,
    ) async -> DeliveryFailureOutcome {
        let failure = DeliveryFailure.from(error)
        if failure.isAuthentication, let id = due.first?.delivery.connectionID {
            await markNeedsSignIn(id)
        }
        if case .rejected = failure {
            let persisted = await abandon(due, connection: connection, failure: failure)
            return DeliveryFailureOutcome(continueDraining: true, persisted: persisted)
        }
        let persisted = await backOff(due, connection: connection, failure: failure)
        return DeliveryFailureOutcome(continueDraining: false, persisted: persisted)
    }

    /// A rejected batch is a permanent refusal of every item in it. The drain
    /// continues with the next batch when one is due.
    func abandon(_ queued: [QueuedDelivery], connection: Connection, failure: ServiceFailure) async -> Bool {
        let reason = DeliveryFailure.message(for: failure)
        var persisted = true
        for item in queued {
            persisted = await abandon(item, reason: reason, kind: connection.kind) && persisted
        }
        return persisted
    }

    private func abandon(_ item: QueuedDelivery, reason: String, kind: ServiceKind) async -> Bool {
        do {
            try await store.abandon(
                item.delivery.id,
                attempts: item.delivery.attempts + 1,
                lastAttemptAt: clock.now,
                reason: reason,
            )
            log(.abandoned(kind: kind, reason: reason))
            return true
        } catch {
            return false
        }
    }

    /// A transport, auth or rate-limit failure backs off every item in the
    /// batch. A rate-limit hint wins when it is later than the schedule.
    func backOff(_ queued: [QueuedDelivery], connection: Connection, failure: ServiceFailure) async -> Bool {
        let now = clock.now
        let reason = DeliveryFailure.message(for: failure)
        var persisted = true

        for item in queued {
            let attempts = item.delivery.attempts + 1
            var delay = retry.delay(afterFailedAttempts: attempts)
            if case let .rateLimited(retryAfter) = failure, let retryAfter, retryAfter > delay {
                delay = retryAfter
            }
            do {
                try await store.markFailed(
                    item.delivery.id,
                    attempts: attempts,
                    at: now,
                    nextAttemptAt: now.addingTimeInterval(delay),
                    error: reason,
                )
            } catch {
                persisted = false
            }
        }
        log(.failed(kind: connection.kind, reason: reason))
        return persisted
    }
}
