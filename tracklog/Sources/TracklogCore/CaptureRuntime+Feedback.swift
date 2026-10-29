import Foundation

// MARK: - Feedback state

extension CaptureRuntime {
    /// Recomputes which feedback actions the current connection set can
    /// perform. Disabled, signed-out and unsupported connections do not count.
    func refreshFeedbackSupport() {
        let eligible = state.connections.filter { $0.isEnabled && $0.authState == .signedIn }
        state.feedbackSupport = FeedbackSupport(
            canLove: eligible.contains {
                feedbackAdapters[$0.kind]?.capabilities.supportsLove == true
            },
            canHate: eligible.contains {
                $0.kind == .listenBrainz
                    && feedbackAdapters[$0.kind]?.capabilities.supportsHate == true
            },
        )
    }

    /// Loads local feedback for processed identities that have not been read
    /// yet. A local write during the read bumps the generation and discards the
    /// stale answer, so it cannot overwrite a newer heart.
    func loadFeedback(for identities: [String]) async {
        guard let feedbackStore else { return }
        let requested = Array(Set(identities.filter { !$0.isEmpty }))
            .filter { !feedbackLoadedIdentities.contains($0) }
        guard !requested.isEmpty else { return }

        let generation = feedbackGeneration
        do {
            let loaded = try await feedbackStore.feedback(for: requested)
            guard generation == feedbackGeneration, !Task.isCancelled else { return }
            var next = state.feedbackByTrack
            for identity in requested {
                next[identity] = loaded[identity]
                feedbackLoadedIdentities.insert(identity)
            }
            state.feedbackByTrack = next
            clearFeedbackFailure()
        } catch {
            recordFeedbackFailure(error)
        }
    }

    /// Loads the current track's heart off the capture path. A track change
    /// cancels the older read and starts the new one; the read itself is keyed
    /// by processed identity, so a late answer cannot move another track's
    /// heart.
    func refreshNowPlayingFeedback() {
        guard let sample = state.nowPlaying else {
            feedbackIdentity = nil
            feedbackLoadTask?.cancel()
            feedbackLoadTask = nil
            return
        }
        let identity = ListenMetadata(sample.track).identity
        guard identity != feedbackIdentity else { return }
        feedbackIdentity = identity
        feedbackLoadTask?.cancel()
        feedbackLoadTask = Task { [weak self] in
            await self?.loadFeedback(for: [identity])
        }
    }

    func recordFeedbackFailure(_ error: Error) {
        state.failure = .feedback(error: error)
    }

    func clearFeedbackFailure() {
        if state.failure?.stage == .feedback {
            state.failure = nil
        }
    }
}

// MARK: - Actions

public extension CaptureRuntime {
    /// Toggles love against every eligible supporting connection. The action
    /// is chosen when the serial queue reaches it, so a love followed by an
    /// unlove cannot both read the old state.
    func toggleLove(for listen: Listen) async {
        guard let id = listen.id else { return }
        let track = listen.processedTrack
        let identity = listen.processed.identity
        await enqueueFeedback { [weak self] in
            guard let self else { return }
            let action: FeedbackAction = state.feedback(for: identity)?.score == .loved
                ? .unlove
                : .love
            await applyFeedback(action, track: track, identity: identity, scope: .listen(id))
        }
    }

    /// Toggles love for the track the pinned strip and widget show.
    func toggleLoveForCurrentTrack() async {
        guard let sample = state.nowPlaying else { return }
        let track = sample.track
        let identity = ListenMetadata(track).identity
        await enqueueFeedback { [weak self] in
            guard let self else { return }
            let action: FeedbackAction = state.feedback(for: identity)?.score == .loved
                ? .unlove
                : .love
            await applyFeedback(action, track: track, identity: identity, scope: .currentTrack)
        }
    }

    /// Hates one history listen. Only supporting ListenBrainz connections are
    /// eligible; Last.fm and Libre.fm never receive it.
    func hate(_ listen: Listen) async {
        guard let id = listen.id else { return }
        let track = listen.processedTrack
        let identity = listen.processed.identity
        await enqueueFeedback { [weak self] in
            guard let self else { return }
            await applyFeedback(.hate, track: track, identity: identity, scope: .listen(id))
        }
    }

    /// Creates an exact artist + title block with blank album and album artist.
    /// Existing history is untouched; the block applies to future captures.
    @discardableResult
    func quickBlock(_ listen: Listen) async throws -> BlockRule {
        try await saveBlock(
            BlockRule(
                track: listen.processed.title,
                artist: listen.processed.artist,
                album: "",
                albumArtist: "",
                savedAt: clock.now,
            ),
        )
    }
}

// MARK: - Ordering and fan-out

private extension CaptureRuntime {
    func enqueueFeedback(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = feedbackChain
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self, started, !Task.isCancelled else { return }
            await operation()
        }
        feedbackChain = task
        await task.value
    }

    func applyFeedback(
        _ action: FeedbackAction,
        track: Track,
        identity: String,
        scope: FeedbackScope,
    ) async {
        guard started, !Task.isCancelled else { return }
        let targets = feedbackTargets(for: action)
        guard !targets.isEmpty, let feedbackStore else { return }

        let now = clock.now
        let score = action.localScore
        do {
            try await feedbackStore.setFeedback(score, for: identity, at: now)
        } catch {
            state.failure = .storage(error: error)
            return
        }

        feedbackGeneration += 1
        feedbackLoadedIdentities.insert(identity)
        var next = state.feedbackByTrack
        next[identity] = score.map { TrackFeedback(identity: identity, score: $0, updatedAt: now) }
        state.feedbackByTrack = next

        guard started, !Task.isCancelled else { return }
        let succeeded = await deliveryOutbox?.sendFeedback(
            action,
            track: track,
            scope: scope,
            connectionIDs: targets.compactMap(\.id),
        ) ?? []
        guard started, !Task.isCancelled, !succeeded.isEmpty else { return }

        showFeedbackHUD(action, services: succeeded.map(\.hudServiceName))
    }

    func showFeedbackHUD(_ action: FeedbackAction, services: [String]) {
        switch action {
        case .love:
            showHUD(.loved(services: services))
        case .unlove:
            showHUD(.unloved(services: services))
        case .hate:
            if let service = services.first {
                showHUD(.hated(service: service))
            }
        }
    }

    func feedbackTargets(for action: FeedbackAction) -> [Connection] {
        state.connections.filter { connection in
            guard connection.isEnabled,
                  connection.authState == .signedIn,
                  let adapter = feedbackAdapters[connection.kind]
            else { return false }
            switch action {
            case .love, .unlove:
                return adapter.capabilities.supportsLove
            case .hate:
                return connection.kind == .listenBrainz && adapter.capabilities.supportsHate
            }
        }
    }
}
