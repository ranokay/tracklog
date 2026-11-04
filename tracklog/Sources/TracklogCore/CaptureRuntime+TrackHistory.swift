import Foundation

// MARK: - Track history

extension CaptureRuntime {
    /// Opens one track's snapshot. The summary and the first page are separate
    /// reads on the dedicated read connection; the count is over the whole
    /// database, not the loaded History page.
    public func openTrackHistory(_ listen: Listen) async {
        guard let key = LocalTrackIdentity.key(
            title: listen.processed.title,
            artist: listen.processed.artist,
        ) else {
            state.trackHistory = TrackHistory(
                identityKey: "",
                title: listen.processed.title,
                artist: listen.processed.artist,
                album: listen.processed.album,
                isLoading: false,
                failure: .history(error: DatabaseError.unavailable("This listen has no track title.")),
            )
            return
        }
        await loadTrackHistory(
            identityKey: key,
            title: listen.processed.title,
            artist: listen.processed.artist,
            album: listen.processed.album,
            preservingRows: false,
        )
    }

    /// Re-reads the open track view. The view is a snapshot, so this is how a
    /// capture or a failed read becomes visible without making capture wait.
    public func reloadTrackHistory() async {
        guard let current = state.trackHistory else { return }
        await loadTrackHistory(
            identityKey: current.identityKey,
            title: current.title,
            artist: current.artist,
            album: current.album,
            preservingRows: true,
        )
    }

    public func loadMoreTrackHistory() async {
        guard started, var track = state.trackHistory, track.hasMore, !track.isLoading,
              let historyStore = store as? any TrackHistoryStore,
              let cursor = track.listens.last.flatMap(ListenCursor.init)
        else { return }

        let request = trackHistoryGeneration
        let load = nextTrackHistoryLoad()
        track.isLoading = true
        state.trackHistory = track
        defer {
            // A page read cancelled by scrolling its footer away never reaches
            // the success or catch body. Release the loading flag so the next
            // footer appearance can retry from the same cursor. A newer load
            // owns the flag and must not be cleared by this one.
            if load == trackHistoryLoadSequence,
               trackHistoryGeneration == request,
               var current = state.trackHistory,
               current.isLoading {
                current.isLoading = false
                state.trackHistory = current
            }
        }
        do {
            let page = try await historyStore.trackHistoryPage(
                matching: track.identityKey,
                limit: historyPageSize,
                before: cursor,
            )
            guard isCurrentTrackHistoryRequest(request), var next = state.trackHistory else { return }
            var known = Set(next.listens.compactMap(\.id))
            for listen in page where listen.id.map({ !known.contains($0) }) ?? false {
                known.insert(listen.id ?? 0)
                next.listens.append(listen)
            }
            next.isLoading = false
            next.failure = nil
            next.hasMore = next.totalCount > next.listens.count
            state.trackHistory = next
            await loadStoredArtwork(for: page)
            await loadFeedback(for: page.map(\.processed.identity))
            await reloadDeliveryState()
        } catch {
            guard isCurrentTrackHistoryRequest(request) else { return }
            recordTrackHistoryFailure(error)
        }
    }

    public func closeTrackHistory() {
        trackHistoryGeneration += 1
        state.trackHistory = nil
    }

    private func loadTrackHistory(
        identityKey: String,
        title: String,
        artist: String,
        album: String,
        preservingRows: Bool,
    ) async {
        guard started, let historyStore = store as? any TrackHistoryStore else { return }
        let request = nextTrackHistoryRequest()
        let opening = TrackHistory(
            identityKey: identityKey,
            title: title,
            artist: artist,
            album: album,
            listens: preservingRows ? state.trackHistory?.listens ?? [] : [],
            totalCount: preservingRows ? state.trackHistory?.totalCount ?? 0 : 0,
            firstListenedAt: preservingRows ? state.trackHistory?.firstListenedAt : nil,
            hasMore: preservingRows ? state.trackHistory?.hasMore ?? false : false,
            isLoading: true,
        )
        state.trackHistory = opening
        do {
            let summary = try await historyStore.trackHistorySummary(matching: identityKey)
            let page = try await historyStore.trackHistoryPage(
                matching: identityKey,
                limit: historyPageSize,
                before: nil,
            )
            guard isCurrentTrackHistoryRequest(request), var track = state.trackHistory else { return }
            track.listens = page
            track.totalCount = summary.count
            track.firstListenedAt = summary.firstListenedAt
            track.hasMore = summary.count > page.count
            track.isLoading = false
            track.failure = nil
            state.trackHistory = track
            await loadStoredArtwork(for: page)
            await loadFeedback(for: page.map(\.processed.identity))
            await reloadDeliveryState()
        } catch {
            guard isCurrentTrackHistoryRequest(request) else { return }
            recordTrackHistoryFailure(error)
        }
    }

    /// A track read failure stays in the track view: it never replaces the
    /// feed, marks capture unavailable, or sets the global failure.
    private func recordTrackHistoryFailure(_ error: Error) {
        guard state.trackHistory != nil else { return }
        state.trackHistory?.isLoading = false
        state.trackHistory?.failure = .history(error: error)
    }

    private func isCurrentTrackHistoryRequest(_ request: Int) -> Bool {
        started
            && request == trackHistoryGeneration
            && !Task.isCancelled
    }

    private func nextTrackHistoryRequest() -> Int {
        trackHistoryGeneration += 1
        return trackHistoryGeneration
    }

    private func nextTrackHistoryLoad() -> Int {
        trackHistoryLoadSequence += 1
        return trackHistoryLoadSequence
    }
}
