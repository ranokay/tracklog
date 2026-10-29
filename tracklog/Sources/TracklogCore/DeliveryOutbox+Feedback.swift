import Foundation

// MARK: - Feedback

public extension DeliveryOutbox {
    /// Sends one love, unlove or hate to the given connections, serialized with
    /// each connection's drain and now playing. Only connections that actually
    /// succeeded are returned, so a caller never counts a skipped or failed
    /// service as a confirmation.
    func sendFeedback(
        _ action: FeedbackAction,
        track: Track,
        scope: FeedbackScope,
        connectionIDs: [Int64],
    ) async -> [Connection] {
        guard isActive else { return [] }
        var succeeded: [Connection] = []
        for id in connectionIDs {
            if let connection = await enqueueFeedback(
                action,
                track: track,
                scope: scope,
                connectionID: id,
            ) {
                succeeded.append(connection)
            }
        }
        return succeeded
    }
}

// MARK: - Feedback

extension DeliveryOutbox {
    private func enqueueFeedback(
        _ action: FeedbackAction,
        track: Track,
        scope: FeedbackScope,
        connectionID id: Int64,
    ) async -> Connection? {
        guard isActive, !suspended.contains(id),
              eligibleFeedbackConnection(id: id, action: action) != nil
        else { return nil }

        let pending = PendingFeedback(action: action, track: track, scope: scope)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending.attach(continuation)
                let worker = worker(for: id)
                worker.feedback.append(pending)
                start(worker, connectionID: id)
            }
        } onCancel: {
            Task { @MainActor in
                pending.cancel()
            }
        }
    }

    private enum FeedbackReferenceOutcome {
        case ready(RecordingReference?)
        case unavailable
    }

    func performFeedback(_ pending: PendingFeedback, connectionID id: Int64) async -> Connection? {
        guard canContinueFeedback(pending, id: id, action: pending.action),
              let connection = eligibleFeedbackConnection(id: id, action: pending.action),
              let adapter = feedbackAdapters[connection.kind],
              let credential = await feedbackCredential(id: id),
              canContinueFeedback(pending, id: id, action: pending.action),
              case let .ready(reference) = await feedbackReference(
                  pending,
                  id: id,
                  adapter: adapter,
                  connection: connection,
                  credential: credential,
              ), !adapter.requiresReference || reference != nil
        else { return nil }

        await waitForSpacing(id: id, interval: adapter.capabilities.minimumRequestInterval)
        guard canContinueFeedback(pending, id: id, action: pending.action) else { return nil }
        lastRequestAt[id] = clock.now

        do {
            try await adapter.submitFeedback(
                pending.action,
                track: pending.track,
                reference: reference,
                connection: connection,
                credential: credential,
            )
        } catch {
            await handleFeedbackFailure(error, connection: connection)
            return nil
        }
        guard canContinueFeedback(pending, id: id, action: pending.action) else { return nil }
        return connection
    }

    private func feedbackCredential(id: Int64) async -> String? {
        switch await lookup.credential(for: id) {
        case let .value(value):
            return value
        case .missing:
            await markNeedsSignIn(id: id)
            return nil
        case .unavailable:
            return nil
        }
    }

    private func feedbackReference(
        _ pending: PendingFeedback,
        id: Int64,
        adapter: any FeedbackAdapter,
        connection: Connection,
        credential: String,
    ) async -> FeedbackReferenceOutcome {
        guard adapter.requiresReference else { return .ready(nil) }
        if let stored = await storedReference(
            for: pending.scope,
            track: pending.track,
            connectionID: id,
        ) {
            return .ready(stored)
        }

        await waitForSpacing(id: id, interval: adapter.capabilities.minimumRequestInterval)
        guard canContinueFeedback(pending, id: id, action: pending.action) else {
            return .unavailable
        }
        lastRequestAt[id] = clock.now
        do {
            let reference = try await adapter.resolveReference(
                for: pending.track,
                connection: connection,
                credential: credential,
            )
            return .ready(reference)
        } catch {
            await handleFeedbackFailure(error, connection: connection)
            return .unavailable
        }
    }

    /// A wait or a lookup may have outlived the connection it started for.
    /// Every await re-checks the lifetime and eligibility rules before the
    /// next request or a success can escape.
    private func canContinueFeedback(
        _ pending: PendingFeedback,
        id: Int64,
        action: FeedbackAction,
    ) -> Bool {
        !pending.isCancelled
            && isActive
            && !Task.isCancelled
            && !suspended.contains(id)
            && eligibleFeedbackConnection(id: id, action: action) != nil
    }

    private func eligibleFeedbackConnection(id: Int64, action: FeedbackAction) -> Connection? {
        guard let connection = lookup.connections.connections.first(where: { $0.id == id }),
              connection.isEnabled,
              connection.authState == .signedIn,
              let adapter = feedbackAdapters[connection.kind],
              supportsFeedback(action, adapter: adapter, connection: connection)
        else { return nil }
        return connection
    }

    private func supportsFeedback(
        _ action: FeedbackAction,
        adapter: any FeedbackAdapter,
        connection: Connection,
    ) -> Bool {
        switch action {
        case .love, .unlove:
            adapter.capabilities.supportsLove
        case .hate:
            connection.kind == .listenBrainz && adapter.capabilities.supportsHate
        }
    }

    /// A history action reads its own delivery row first; a current-track
    /// action may use the retained now-playing reference only for the same
    /// track. Lookup is the fallback when neither has a reference.
    private func storedReference(
        for scope: FeedbackScope,
        track: Track,
        connectionID id: Int64,
    ) async -> RecordingReference? {
        switch scope {
        case .currentTrack:
            return nowPlayingReference(forConnection: id, track: track)
        case let .listen(listenID):
            guard let deliveries = try? await store.deliveries(for: listenID),
                  let stored = deliveries.first(where: { $0.connectionID == id })?.serviceReference
            else { return nil }
            let reference = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            return reference.isEmpty ? nil : .msid(reference)
        }
    }

    func nowPlayingReference(forConnection id: Int64, track: Track) -> RecordingReference? {
        guard nowPlayingReferenceTracks[id] == track.identity,
              let reference = nowPlayingReferences[id]
        else { return nil }
        return .msid(reference)
    }

    func clearRecordingReference(id: Int64) {
        nowPlayingReferences[id] = nil
        nowPlayingReferenceTracks[id] = nil
    }

    private func handleFeedbackFailure(_ error: any Error, connection: Connection) async {
        let failure = DeliveryFailure.from(error)
        if failure.isAuthentication, let id = connection.id {
            await markNeedsSignIn(id: id)
        }
        if let problem = failure.appCredentialProblem {
            onAppCredentialProblem?(connection.kind, problem)
        }
    }

    /// A successful ListenBrainz delivery keeps the retained now-playing MSID
    /// on its own delivery row, scoped to that listen and connection. The
    /// service adapter stays unaware of the outbox's retained reference.
    func enrichedDeliveryResult(
        _ result: DeliveryResult,
        queued: QueuedDelivery,
        connection: Connection,
    ) -> DeliveryResult {
        guard case .delivered = result,
              connection.kind == .listenBrainz,
              let id = connection.id,
              case let .msid(reference)? = nowPlayingReference(
                  forConnection: id,
                  track: queued.listen.processedTrack,
              )
        else { return result }
        return .delivered(reference: reference)
    }
}
