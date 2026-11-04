import Foundation

// MARK: - Local history mutations

public extension CaptureRuntime {
    /// Corrects one stored listen. The optional rule is saved in the same
    /// transaction and affects future plays only.
    ///
    /// Success is published only after the store commits. A validation or
    /// storage failure leaves the loaded feed unchanged and throws to the
    /// caller, which must not dismiss a page or show a confirmation.
    @discardableResult
    func editListen(
        _ listen: Listen,
        to metadata: ListenMetadata,
        rememberAsRule: Bool,
    ) async throws -> Listen {
        guard let id = listen.id else { throw ListenMutationError.notFound }
        guard let baseStore = store, let mutationStore = baseStore as? any ListenMutationStore else {
            throw DatabaseError.unavailable("local history editing is unavailable")
        }

        let trimmed = metadata.trimmedForEdit
        guard trimmed.isValidEditedMetadata else { throw ListenMutationError.invalidMetadata }
        let rule = rememberAsRule ? rememberedRule(for: listen, edited: trimmed) : nil

        let result: ListenEditResult
        do {
            result = try await mutationStore.editListen(id: id, to: trimmed, remembering: rule)
        } catch let error as ListenMutationError {
            throw error
        } catch let error as SimpleEditRuleValidationError {
            throw error
        } catch {
            if started {
                state.failure = .storage(error: error)
            }
            throw error
        }
        guard started, !Task.isCancelled else { return result.listen }

        // Publish the corrected row immediately so a failed reload cannot put
        // the old values back on screen. A track view is closed because the
        // edited key may no longer match it.
        state.listens = state.listens.map { $0.id == id ? result.listen : $0 }
        closeTrackHistory()
        if result.rule != nil {
            await loadSimpleEdits()
        }
        await reloadVisibleHistory(in: baseStore)
        await reloadDeliveryState()
        await charts?.localHistoryChanged()
        return result.listen
    }

    /// Removes one stored listen from local history. Pending retries stop
    /// because their delivery rows are removed with it; no remote call is made.
    func deleteListen(_ listen: Listen) async throws {
        guard let id = listen.id else { throw ListenMutationError.notFound }
        guard let baseStore = store, let mutationStore = baseStore as? any ListenMutationStore else {
            throw DatabaseError.unavailable("local history deletion is unavailable")
        }

        do {
            try await mutationStore.deleteListen(id: id, at: clock.now)
        } catch let error as ListenMutationError {
            throw error
        } catch {
            if started {
                state.failure = .storage(error: error)
            }
            throw error
        }
        guard started, !Task.isCancelled else { return }

        state.listens.removeAll { $0.id == id }
        state.historyCount = max(0, state.historyCount - 1)
        if state.trackHistory != nil {
            await reloadTrackHistory()
        }
        await reloadVisibleHistory(in: baseStore)
        await reloadDeliveryState()
        await charts?.localHistoryChanged()
    }
}

// MARK: - Remember as rule

private extension CaptureRuntime {
    /// Matches every non-empty sentinel-cleaned raw field, exactly as the
    /// existing Edit action pre-fills a rule. Only fields the one-off edit
    /// changed become replacements, so an unchanged album does not pin future
    /// plays to it.
    func rememberedRule(for listen: Listen, edited: ListenMetadata) -> SimpleEditRule? {
        let cleaned = MetadataPipeline.sentinelCleanup(listen.raw)
        var replacement = SimpleEditRule.Replacement()
        if edited.title != listen.processed.title {
            replacement.track = edited.title
        }
        if edited.artist != listen.processed.artist {
            replacement.artist = edited.artist
        }
        if edited.album != listen.processed.album {
            replacement.album = edited.album
        }
        if edited.albumArtist != listen.processed.albumArtist {
            replacement.albumArtist = edited.albumArtist
        }
        guard replacement.activeCount > 0 else { return nil }
        return SimpleEditRule(
            match: .prefilled(from: cleaned),
            replacement: replacement,
            savedAt: clock.now,
        )
    }
}
