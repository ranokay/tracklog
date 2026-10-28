import Foundation

// MARK: - Artwork

extension CaptureRuntime {
    /// Starts one artwork task per track identity change. The task is separate
    /// from `consume`, so a cover lookup, an image decode or a slow disk write
    /// can never hold up the scrobble.
    func resolveArtwork(for track: Track) {
        let identity = ListenMetadata(track).identity
        guard source.mediaStatus.source == .helper else {
            showNeutralArtwork(for: identity)
            return
        }
        guard identity != artworkIdentity else { return }

        artworkIdentity = identity
        artworkTask?.cancel()
        state.nowPlayingArtwork = nil
        state.nowPlayingArtworkIdentity = identity
        artworkTask = Task { [weak self] in
            await self?.loadArtwork(for: track, identity: identity)
        }
    }

    /// Automation cannot supply a cover. Keep the raw identity for the
    /// neutral sleeve, but drop any helper image from an earlier sample.
    private func showNeutralArtwork(for identity: String) {
        guard artworkTask != nil || state.nowPlayingArtwork != nil || state.nowPlayingArtworkIdentity != identity else {
            return
        }
        artworkTask?.cancel()
        artworkTask = nil
        artworkIdentity = nil
        state.nowPlayingArtwork = nil
        state.nowPlayingArtworkIdentity = identity
    }

    /// Waits for the artwork task started for the current identity. The
    /// harness uses this so a surface shot never races the cover read.
    public func waitForArtwork() async {
        await artworkTask?.value
    }

    func clearArtwork() {
        guard artworkIdentity != nil || artworkTask != nil || state.nowPlayingArtwork != nil else { return }
        artworkTask?.cancel()
        artworkTask = nil
        artworkIdentity = nil
        state.nowPlayingArtwork = nil
        state.nowPlayingArtworkIdentity = nil
    }

    /// Loads covers for the listens currently in the feed. This is a local
    /// read by content hash; it never contacts a network or the media helper.
    func loadStoredArtwork(for listens: [Listen]) async {
        guard let artworkStore else { return }
        let missing = Set(listens.compactMap(\.artworkHash))
            .filter { state.artworkByHash[$0] == nil }

        for hash in missing {
            guard let data = try? await artworkStore.artwork(for: hash) else { continue }
            guard !Task.isCancelled, started else { return }
            state.artworkByHash[hash] = data
        }
    }

    private func loadArtwork(for track: Track, identity: String) async {
        // A cover already known for this track, from an earlier listen or an
        // earlier launch, is reused before the helper is asked again. That
        // includes Automation: it cannot supply new art, but a known cover is
        // still the best available one. Only short local queries and writes
        // touch the store actor; the helper read and image encode happen off it.
        if let artworkStore,
           let hash = try? await artworkStore.artworkHash(forTrack: identity),
           let data = try? await artworkStore.artwork(for: hash) {
            guard !Task.isCancelled, artworkIdentity == identity else { return }
            applyArtwork(data, hash: hash, identity: identity)
            return
        }

        guard let bytes = await source.artwork(for: track), !Task.isCancelled, artworkIdentity == identity else { return }

        let normalize = Task.detached(priority: .utility) {
            ArtworkNormalizer.normalize(bytes)
        }
        let artwork = await normalize.value
        guard let artwork, !Task.isCancelled, artworkIdentity == identity else { return }

        // A failed write still lets this session show the cover; it only means
        // the next launch may have to fetch it again.
        var persisted = artworkStore == nil
        if let artworkStore {
            do {
                try await artworkStore.attachArtwork(artwork, toTrack: identity)
                persisted = true
            } catch {
                persisted = false
            }
        }
        guard !Task.isCancelled, artworkIdentity == identity else { return }

        state.nowPlayingArtwork = artwork.data
        state.artworkByHash[artwork.hash] = artwork.data
        if persisted {
            updateVisibleListens(for: identity, with: artwork.hash)
        }
    }

    private func applyArtwork(_ data: Data, hash: String, identity: String) {
        state.nowPlayingArtwork = data
        state.artworkByHash[hash] = data
        updateVisibleListens(for: identity, with: hash)
    }

    private func updateVisibleListens(for identity: String, with hash: String) {
        // Only cover-less rows are filled. A listen already captured with an
        // older cover keeps it, matching the store's update rule.
        state.listens = state.listens.map { listen in
            guard listen.raw.identity == identity, listen.artworkHash == nil else { return listen }
            return listen.withArtworkHash(hash)
        }
    }
}
