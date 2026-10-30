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
    /// yet. A local write protects only its own identity from the stale answer;
    /// untouched identities in the same read still apply.
    func loadFeedback(for identities: [String]) async {
        guard let feedbackStore else { return }
        let requested = Array(Set(identities.filter { !$0.isEmpty }))
            .filter { !feedbackLoadedIdentities.contains($0) }
        guard !requested.isEmpty else { return }

        let revisions = Dictionary(
            uniqueKeysWithValues: requested.map {
                ($0, feedbackWriteRevisions[$0, default: 0])
            },
        )
        do {
            let loaded = try await feedbackStore.feedback(for: requested)
            guard !Task.isCancelled else { return }
            var next = state.feedbackByTrack
            for identity in requested {
                guard feedbackWriteRevisions[identity, default: 0] == revisions[identity] else {
                    continue
                }
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
            guard let self else { return }
            await loadFeedback(for: [identity])
            guard !Task.isCancelled,
                  state.nowPlaying.map({ ListenMetadata($0.track).identity }) == identity,
                  !feedbackLoadedIdentities.contains(identity)
            else { return }
            // The answer was discarded or failed; let the next sample retry it.
            feedbackIdentity = nil
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
        await enqueueFeedback { [weak self] generation in
            guard let self,
                  let action = await loveAction(for: identity, generation: generation)
            else { return }
            await applyFeedback(
                action,
                track: track,
                identity: identity,
                scope: .listen(id),
                generation: generation,
            )
        }
    }

    /// Toggles love for the track the pinned strip and widget show.
    func toggleLoveForCurrentTrack() async {
        guard let sample = state.nowPlaying else { return }
        let track = sample.track
        let identity = ListenMetadata(track).identity
        await enqueueFeedback { [weak self] generation in
            guard let self,
                  let action = await loveAction(for: identity, generation: generation)
            else { return }
            await applyFeedback(
                action,
                track: track,
                identity: identity,
                scope: .currentTrack,
                generation: generation,
            )
        }
    }

    /// Hates one history listen. Only supporting ListenBrainz connections are
    /// eligible; Last.fm and Libre.fm never receive it.
    func hate(_ listen: Listen) async {
        guard let id = listen.id else { return }
        let track = listen.processedTrack
        let identity = listen.processed.identity
        await enqueueFeedback { [weak self] generation in
            guard let self else { return }
            await applyFeedback(
                .hate,
                track: track,
                identity: identity,
                scope: .listen(id),
                generation: generation,
            )
        }
    }

    /// Creates an exact artist + title block with blank album and album artist.
    /// Existing history is untouched; the block applies to future captures.
    ///
    /// The raw values are the ones the next play arrives with. Blocks run
    /// before simple edits, so blocking the processed display values would let
    /// a rule-rewritten track through on its next play.
    @discardableResult
    func quickBlock(_ listen: Listen) async throws -> BlockRule {
        try await saveBlock(
            BlockRule(
                track: listen.raw.title,
                artist: listen.raw.artist,
                album: "",
                albumArtist: "",
                savedAt: clock.now,
            ),
        )
    }

    /// Creates the same raw artist + title block for the track in flight. The
    /// engine keeps the player's raw observation while `state.nowPlaying`
    /// publishes the edited values, so the block is authored against what the
    /// next play will actually arrive as.
    @discardableResult
    func quickBlockCurrentTrack() async throws -> BlockRule? {
        guard let raw = engine.currentRawTrack else { return nil }
        return try await saveBlock(
            BlockRule(
                track: raw.title,
                artist: raw.artist,
                album: "",
                albumArtist: "",
                savedAt: clock.now,
            ),
        )
    }
}

// MARK: - Ordering and fan-out

private extension CaptureRuntime {
    func enqueueFeedback(_ operation: @escaping @MainActor (Int) async -> Void) async {
        let generation = startGeneration
        let previous = feedbackChain
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self, started, startGeneration == generation, !Task.isCancelled else {
                return
            }
            await operation(generation)
        }
        feedbackChain = task
        await task.value
    }

    /// The latest durable state for an identity that has not been read yet.
    /// This is an action-path read, never part of capture. A read that outlives
    /// its activation or is overtaken by a newer identity write is discarded,
    /// and a required read failure aborts the toggle rather than guessing.
    func loveAction(for identity: String, generation: Int) async -> FeedbackAction? {
        guard started, startGeneration == generation, !Task.isCancelled else { return nil }
        if feedbackLoadedIdentities.contains(identity) {
            return state.feedback(for: identity)?.score == .loved ? .unlove : .love
        }
        guard let feedbackStore else { return nil }

        let revision = feedbackWriteRevisions[identity, default: 0]
        do {
            let loaded = try await feedbackStore.feedback(for: [identity])
            guard started,
                  startGeneration == generation,
                  !Task.isCancelled,
                  feedbackWriteRevisions[identity, default: 0] == revision
            else { return nil }
            state.feedbackByTrack[identity] = loaded[identity]
            feedbackLoadedIdentities.insert(identity)
            clearFeedbackFailure()
        } catch {
            guard started, startGeneration == generation, !Task.isCancelled else { return nil }
            recordFeedbackFailure(error)
            return nil
        }
        return state.feedback(for: identity)?.score == .loved ? .unlove : .love
    }

    func applyFeedback(
        _ action: FeedbackAction,
        track: Track,
        identity: String,
        scope: FeedbackScope,
        generation: Int,
    ) async {
        guard started, startGeneration == generation, !Task.isCancelled else { return }
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

        guard started, startGeneration == generation, !Task.isCancelled else { return }
        feedbackWriteRevisions[identity, default: 0] += 1
        feedbackLoadedIdentities.insert(identity)
        var next = state.feedbackByTrack
        next[identity] = score.map { TrackFeedback(identity: identity, score: $0, updatedAt: now) }
        state.feedbackByTrack = next

        guard started, startGeneration == generation, !Task.isCancelled else { return }
        let succeeded = await deliveryOutbox?.sendFeedback(
            action,
            track: track,
            scope: scope,
            connectionIDs: targets.compactMap(\.id),
        ) ?? []
        guard started, startGeneration == generation, !Task.isCancelled, !succeeded.isEmpty else {
            return
        }

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
