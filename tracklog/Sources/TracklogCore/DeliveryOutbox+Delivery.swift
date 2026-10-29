import Foundation

extension DeliveryOutbox {
    /// Manual retry: makes every pending row for the connection due now and
    /// drains it. Attempts are kept, so repeated failures still reach the cap.
    public func retry(connectionID: Int64) {
        guard isActive else { return }
        suspended.remove(connectionID)
        blockedUntil[connectionID] = nil
        Task { @MainActor [weak self] in
            guard let self, isActive else { return }
            try? await store.markDue(for: connectionID, at: clock.now)
            drain(connectionIDs: [connectionID])
        }
    }

    func apply(
        _ results: [DeliveryResult],
        to due: [QueuedDelivery],
        connection: Connection,
    ) async -> DeliveryApplyOutcome {
        var persisted = true
        var continueDraining = true
        for (queued, result) in zip(due, results) {
            if case .rateLimited = result {
                // A daily-limit answer will repeat for the next batch too; stop
                // after recording this one instead of burning a request per
                // batch.
                continueDraining = false
            }
            let enriched = enrichedDeliveryResult(result, queued: queued, connection: connection)
            let written = await writer.apply(enriched, to: queued, connection: connection)
            if written, case .delivered = enriched, let id = connection.id {
                onDeliverySucceeded?(connection.kind, id)
            }
            persisted = written && persisted
        }
        return DeliveryApplyOutcome(continueDraining: continueDraining, persisted: persisted)
    }

    func sendNowPlaying(_ track: Track, connectionID id: Int64) async {
        guard let connection = lookup.connection(id: id),
              let adapter = lookup.adapters[connection.kind],
              adapter.capabilities.supportsNowPlaying,
              case let .value(credential) = await lookup.credential(for: id) else { return }

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
                nowPlayingReferenceTracks[id] = track.identity
            } else {
                // A newer now playing without a reference must not leave the
                // previous track's reference looking current.
                clearRecordingReference(id: id)
            }
        } catch let failure as ServiceFailure {
            // Now playing is never retried, but a rejected credential still
            // changes the connection so deliveries stop retrying it.
            if failure.isAuthentication {
                await markNeedsSignIn(id: id)
            }
            if let problem = failure.appCredentialProblem {
                onAppCredentialProblem?(connection.kind, problem)
            }
            writer.log(.failed(kind: connection.kind, reason: DeliveryFailure.message(for: failure)))
        } catch {
            writer.log(.failed(kind: connection.kind, reason: DeliveryFailure.message(for: .retryable)))
        }
    }

    func markNeedsSignIn(id: Int64) async {
        guard await (try? lookup.connections.markNeedsSignIn(id: id)) != nil else { return }
        onConnectionsChanged?()
    }

    func waitForSpacing(id: Int64, interval: TimeInterval) async {
        guard interval > 0, let last = lastRequestAt[id] else { return }
        let due = last.addingTimeInterval(interval)
        guard due > clock.now else { return }
        try? await clock.sleep(until: due)
    }
}
