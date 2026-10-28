import Foundation

/// Applies one batch's outcomes and one batch's backoff. Kept apart from the
/// drain loop so the loop reads as scheduling rather than bookkeeping.
@MainActor
struct DeliveryOutboxWriter {
    let store: any DeliveryStore
    let clock: any Clock
    let retry: DeliveryRetrySchedule
    let log: @MainActor (DeliveryEvent) -> Void

    func apply(_ result: DeliveryResult, to queued: QueuedDelivery, connection: Connection) async {
        switch result {
        case let .delivered(reference):
            do {
                try await store.markDelivered(
                    queued.delivery.id,
                    at: clock.now,
                    reference: reference,
                )
                log(.delivered(kind: connection.kind, count: 1))
            } catch {
                // The row stays pending and a later drain retries it.
            }
        case let .rejected(message):
            let reason = DeliveryFailure.normalized(message) ?? "The service rejected this listen."
            do {
                try await store.abandon(
                    queued.delivery.id,
                    attempts: queued.delivery.attempts + 1,
                    at: clock.now,
                    reason: reason,
                )
                log(.abandoned(kind: connection.kind, reason: reason))
            } catch {
                // The row stays pending; abandoning again is safe.
            }
        }
    }

    /// A rejected batch is a permanent refusal of every item in it. The drain
    /// continues with the next batch when one is due.
    func abandon(_ queued: [QueuedDelivery], connection: Connection, failure: ServiceFailure) async {
        let reason = DeliveryFailure.message(for: failure)
        for item in queued {
            do {
                try await store.abandon(
                    item.delivery.id,
                    attempts: item.delivery.attempts + 1,
                    at: clock.now,
                    reason: reason,
                )
                log(.abandoned(kind: connection.kind, reason: reason))
            } catch {
                // The row stays pending and a later drain retries it.
            }
        }
    }

    /// A transport, auth or rate-limit failure backs off every item in the
    /// batch. A rate-limit hint wins when it is later than the schedule.
    func backOff(_ queued: [QueuedDelivery], connection: Connection, failure: ServiceFailure) async {
        let now = clock.now
        let reason = DeliveryFailure.message(for: failure)

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
                // The row stays due and a later trigger retries it.
            }
        }
        log(.failed(kind: connection.kind, reason: reason))
    }
}
