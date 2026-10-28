import Foundation

// MARK: - Ingest

extension CaptureRuntime {
    /// Feeds one observation through the engine and, when the threshold is
    /// crossed, into durable history. Public so tests replay samples without
    /// sleeping on a feed.
    public func ingest(_ sample: MediaSample?) async {
        guard started, state.scrobblingEnabled, state.pausedUntil == nil, let store else { return }

        // The allowlist is a gate, not a filter: a denied app produces no now
        // playing, no history and no delivery, and its sample must not keep an
        // older allowed session alive.
        guard let sample, await isAppAllowed(sample.track.bundleID) else {
            await consume(nil, raw: nil, into: store)
            return
        }

        // The allowlist read above can suspend; pause or switch-off may have
        // landed in the meantime. Do not let the sample re-arm the engine.
        guard !Task.isCancelled, started, state.scrobblingEnabled, state.pausedUntil == nil else { return }

        // A sample the metadata pipeline rejects (no title or artist after
        // cleanup, blocks, edits and trimming) is not a candidate for now
        // playing or history, and must not arm the engine.
        guard let processed = MetadataPipeline.process(
            sample.track,
            edits: state.simpleEdits,
            blocks: state.blocks,
        ) else {
            await consume(nil, raw: nil, into: store)
            return
        }

        // Now playing shows the processed values; the engine keeps the raw
        // observation so its session identity stays the player's.
        await consume(sample.replacingMetadata(processed), raw: sample, into: store)
    }

    private func consume(
        _ displayed: MediaSample?,
        raw: MediaSample?,
        into store: any ListenStore,
    ) async {
        // The allowlist read can suspend, and pause or switch-off can land
        // while it is in flight. Re-check every gate so a stale sample cannot
        // re-arm a feed that was just stopped.
        guard started, state.scrobblingEnabled, state.pausedUntil == nil else { return }

        state.nowPlaying = displayed
        if displayed != nil, let raw {
            resolveArtwork(for: raw.track)
        } else {
            clearArtwork()
        }
        // The toggle is applied while the sample is ingested, so with it off
        // nothing is marked as already sent and turning it on can still start
        // now playing for the same track.
        let effects = engine.ingest(
            raw,
            submitted: displayed?.track,
            nowPlayingEnabled: state.nowPlayingEnabled,
        )
        state.status = engine.status

        for effect in effects {
            switch effect {
            case let .nowPlaying(track):
                sendNowPlaying?(track)
                deliveryOutbox?.sendNowPlaying(track)
            case let .scrobble(scrobble):
                await persist(scrobble, in: store)
            }
        }
    }

    /// Persists one threshold-crossing listen. A write admitted before a stop
    /// or switch-off may finish, but it cannot publish history after either;
    /// nothing new is admitted.
    private func persist(_ scrobble: Scrobble, in store: any ListenStore) async {
        guard !Task.isCancelled, started, state.scrobblingEnabled else { return }
        let listen = Listen(
            scrobble: scrobble,
            processed: ListenMetadata(scrobble.submitted),
            capturedAt: clock.now,
        )
        // Targets are the connections enabled at this instant. A connection
        // paused now is not a target and is never backfilled on re-enable.
        let targets = (connectionService?.connections ?? [])
            .filter(\.isEnabled)
            .compactMap(\.id)

        do {
            let stored: Listen? = if let deliveryStore {
                try await deliveryStore.insert(listen, targets: targets)
            } else {
                try await store.insert(listen)
            }
            guard let stored,
                  !Task.isCancelled, started, state.scrobblingEnabled
            else { return }
            state.lastListen = stored
            state.listenCount += 1
            state.historyCount += 1
            await reloadVisibleHistory(in: store)
            deliveryOutbox?.drain(connectionIDs: targets)
        } catch {
            guard !Task.isCancelled, started, state.scrobblingEnabled else { return }
            state.failure = .storage(error: error)
        }
    }
}
