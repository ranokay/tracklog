import Foundation

// MARK: - Blocks

extension CaptureRuntime {
    /// Loads the blocks the pipeline evaluates and the Blocks page lists. A
    /// read failure leaves the previous blocks in place, surfaces the failure,
    /// and capture continues with that set.
    func loadBlocks() async {
        guard let blockStore else { return }
        do {
            state.blocks = try await blockStore.blocks()
            state.blocksFailure = nil
            if state.failure?.stage == .blocks {
                state.failure = nil
            }
        } catch {
            let failure = CaptureFailure.blocks(error: error)
            state.blocksFailure = failure
            state.failure = failure
        }
    }
}

public extension CaptureRuntime {
    /// Saves a block, then refreshes the list so the page shows the store's
    /// order and assigned id. Validation and storage errors reach the caller.
    @discardableResult
    func saveBlock(_ block: BlockRule) async throws -> BlockRule {
        guard let blockStore else {
            throw DatabaseError.unavailable("blocks are unavailable")
        }
        let saved = try await blockStore.save(block)
        await loadBlocks()
        if let title = blockHUDTitle(saved) {
            showHUD(.blocked(title: title))
        }
        return saved
    }

    private func blockHUDTitle(_ block: BlockRule) -> String? {
        [block.track, block.artist, block.album, block.albumArtist]
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    func deleteBlock(id: Int64) async throws {
        guard let blockStore else {
            throw DatabaseError.unavailable("blocks are unavailable")
        }
        try await blockStore.deleteBlock(id: id)
        await loadBlocks()
    }

    /// Creates an exact artist + title block with blank album and album artist.
    /// Existing history is untouched; the block applies to future captures.
    ///
    /// The raw values are the ones the next play arrives with. Blocks run
    /// before simple edits, so blocking the processed display values would let
    /// a rule-rewritten track through on its next play.
    @discardableResult
    func quickBlock(_ listen: Listen) async throws -> BlockRule {
        try await quickSaveBlock(
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
        return try await quickSaveBlock(
            BlockRule(
                track: raw.title,
                artist: raw.artist,
                album: "",
                albumArtist: "",
                savedAt: clock.now,
            ),
        )
    }

    /// A quick block has no form to show an error in, so a failed save says
    /// so on the notch. The Blocks settings page keeps its inline error.
    private func quickSaveBlock(_ block: BlockRule) async throws -> BlockRule {
        do {
            return try await saveBlock(block)
        } catch {
            let title = block.track.trimmingCharacters(in: .whitespacesAndNewlines)
            showHUD(.blockFailed(title: title.isEmpty ? "this track" : title))
            throw error
        }
    }
}
