// swiftlint:disable file_length
import Foundation
import Testing
@testable import TracklogCore

@Suite("Local history mutation")
@MainActor
// swiftlint:disable:next type_body_length
struct HistoryMutationTests {
    @Test func anEditChangesOnlyTheProcessedValuesAndSurvivesRestart() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let original = mutationListen()
        let stored = try #require(try await store.insert(original))
        let runtime = makeMutationRuntime(store: store)
        await runtime.start()

        let values = ListenMetadata(
            title: "  Corrected  ",
            artist: "Artist",
            album: "",
            albumArtist: "",
        )
        let edited = try await runtime.editListen(stored, to: values, rememberAsRule: false)

        #expect(edited.id == stored.id)
        #expect(edited.raw == stored.raw)
        #expect(edited.processed == ListenMetadata(
            title: "Corrected",
            artist: "Artist",
            album: "",
            albumArtist: "",
        ))
        #expect(edited.startedAt == stored.startedAt)
        #expect(edited.capturedAt == stored.capturedAt)
        #expect(edited.bundleID == stored.bundleID)
        #expect(edited.duration == stored.duration)
        #expect(edited.playedDuration == stored.playedDuration)
        #expect(edited.artworkHash == stored.artworkHash)
        #expect(edited.dedupKey == stored.dedupKey)
        #expect(runtime.state.listens.first?.processed.title == "Corrected")
        #expect(try await store.count() == 1)

        runtime.stop()
        await store.close()
        let reopened = try SQLiteListenStore(url: database.url)
        let rows = try await reopened.page(limit: 10, before: nil)
        #expect(rows.count == 1)
        #expect(rows.first?.processed.title == "Corrected")
        #expect(rows.first?.raw.title == "Song")
        #expect(rows.first?.dedupKey == stored.dedupKey)
    }

    @Test func aBlankTitleOrArtistIsRefusedWithoutChangingTheRow() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let stored = try #require(try await store.insert(mutationListen()))
        let runtime = makeMutationRuntime(store: store)
        await runtime.start()

        do {
            _ = try await runtime.editListen(
                stored,
                to: ListenMetadata(title: " ", artist: "Artist"),
                rememberAsRule: false,
            )
            Issue.record("an empty title must be refused")
        } catch let error as ListenMutationError {
            #expect(error == .invalidMetadata)
        }

        let rows = try await store.page(limit: 10, before: nil)
        #expect(rows.first?.processed.title == "Song")
        #expect(runtime.state.listens.first?.processed.title == "Song")
    }

    @Test func anEditAndDeleteLeaveTrackFeedbackAndSharedArtwork() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let original = mutationListen()
        let artwork = StoredArtwork(
            hash: "cover-hash",
            data: Data([1, 2, 3]),
            pixelWidth: 1,
            pixelHeight: 1,
        )
        try await store.attachArtwork(artwork, toTrack: original.raw.identity)
        let stored = try #require(try await store.insert(original))
        #expect(stored.artworkHash == "cover-hash")
        try await store.setFeedback(.loved, for: stored.processed.identity, at: mutationBase)

        let runtime = makeMutationRuntime(store: store)
        await runtime.start()
        let edited = try await runtime.editListen(
            stored,
            to: ListenMetadata(title: "Corrected", artist: "Artist"),
            rememberAsRule: false,
        )

        #expect(edited.artworkHash == "cover-hash")
        let oldFeedback = try await store.feedback(for: [stored.processed.identity])
        #expect(oldFeedback[stored.processed.identity]?.score == .loved)
        let newFeedback = try await store.feedback(for: [edited.processed.identity])
        #expect(newFeedback[edited.processed.identity] == nil)
        #expect(runtime.state.feedback(for: edited.processed.identity) == nil)

        try await runtime.deleteListen(edited)

        #expect(try await store.artwork(for: "cover-hash") == Data([1, 2, 3]))
        #expect(try await store.artworkHash(forTrack: original.raw.identity) == "cover-hash")
        let afterDelete = try await store.feedback(for: [stored.processed.identity])
        #expect(afterDelete[stored.processed.identity]?.score == .loved)
        #expect(try await store.deliveries(for: stored.id ?? -1).isEmpty)
    }

    @Test func aDeletedListenIsNotRecapturedButANewStartIsARepeat() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let original = mutationListen()
        let stored = try #require(try await store.insert(original))
        let runtime = makeMutationRuntime(store: store)
        await runtime.start()

        try await runtime.deleteListen(stored)

        #expect(try await store.count() == 0)
        #expect(try await store.tombstoneCount() == 1)
        let hashes = try await store.tombstoneHashes()
        let hash = try #require(hashes.first)
        let isHex = hash.allSatisfy { character in character.isHexDigit }
        #expect(hash.count == 64)
        #expect(isHex)
        #expect(!hash.contains("Song"))
        #expect(!hash.contains("Artist"))
        #expect(!hash.contains("Album"))
        #expect(!hash.contains(stored.dedupKey))

        #expect(try await store.insert(original) == nil, "the same play stays deleted")
        let repeatPlay = mutationListen(
            start: mutationBase.addingTimeInterval(60),
        )
        #expect(try await store.insert(repeatPlay) != nil)

        runtime.stop()
        await store.close()
        let reopened = try SQLiteListenStore(url: database.url)
        #expect(try await reopened.tombstoneCount() == 1)
        #expect(try await reopened.insert(original) == nil)
        #expect(try await reopened.count() == 1)
    }

    @Test func anEditRefreshesHistoryTrackAndChartReads() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let stored = try #require(try await store.insert(mutationListen()))
        let runtime = makeMutationRuntime(store: store)
        await runtime.start()

        let charts = try #require(runtime.charts)
        await charts.selectSource(.local)
        await charts.selectType(.tracks)
        await charts.selectPeriod(.allTime)
        await charts.show()
        #expect(runtime.state.chartState.snapshot?.items.map(\.title) == ["Song"])
        #expect(try await store.chartCacheCount() > 0)

        charts.hide()
        let edited = try await runtime.editListen(
            stored,
            to: ListenMetadata(title: "Corrected", artist: "Artist", album: "Album"),
            rememberAsRule: false,
        )

        #expect(runtime.state.chartState.snapshot == nil)
        #expect(try await store.chartCacheCount() == 0)
        let oldKey = LocalTrackIdentity.key(title: "Song", artist: "Artist")
        let newKey = LocalTrackIdentity.key(title: "Corrected", artist: "Artist")
        #expect(try await store.trackHistorySummary(matching: oldKey ?? "").count == 0)
        #expect(try await store.trackHistorySummary(matching: newKey ?? "").count == 1)

        await charts.show()
        #expect(runtime.state.chartState.snapshot?.items.map(\.title) == ["Corrected"])
        #expect(runtime.state.chartState.snapshot?.localTotal == 1)

        await openTrackDetail(runtime, edited)
        #expect(runtime.state.entityDetail?.track?.totalCount == 1)
        try await runtime.deleteListen(edited)
        #expect(runtime.state.entityDetail?.track?.totalCount == 0)
        #expect(runtime.state.entityDetail?.track?.listens.isEmpty == true)
    }

    @Test func aWaitingDeliveryKeepsItsStateAndSendsEditedValues() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let adapter = RecordingDeliveryAdapter()
        let runtime = makeMutationRuntime(store: store, adapters: [adapter])
        await runtime.start()
        let connection = try await runtime.link(kind: .listenBrainz, credential: "token")
        try await runtime.setConnectionEnabled(id: connection.id ?? -1, enabled: false)
        let stored = try #require(
            try await store.insert(mutationListen(), targets: [connection.id ?? -1]),
        )
        let pending = try #require(try await store.deliveries(for: stored.id ?? -1).first)

        let edited = try await runtime.editListen(
            stored,
            to: ListenMetadata(title: "Corrected", artist: "Artist", album: "Album"),
            rememberAsRule: false,
        )
        let held = try #require(try await store.deliveries(for: stored.id ?? -1).first)
        #expect(held.state == .waiting)
        #expect(held.attempts == 0)
        #expect(held.nextAttemptAt == pending.nextAttemptAt)
        #expect(held.connectionID == pending.connectionID)

        let clock = try #require(runtime.clock as? FakeClock)
        clock.advance(to: held.nextAttemptAt ?? clock.now)
        try await runtime.setConnectionEnabled(id: connection.id ?? -1, enabled: true)
        let batches = await awaitBatches(adapter, count: 1)
        #expect(batches.first?.first?.processed.title == "Corrected")
        #expect(batches.first?.first?.id == edited.id)
    }

    @Test func aRetryingDeliveryKeepsItsBackoffAndSendsEditedValues() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let adapter = RecordingDeliveryAdapter(answers: [.failure(.retryable)])
        let runtime = makeMutationRuntime(store: store, adapters: [adapter])
        await runtime.start()
        let connection = try await runtime.link(kind: .listenBrainz, credential: "token")
        try await runtime.setConnectionEnabled(id: connection.id ?? -1, enabled: false)
        let stored = try #require(
            try await store.insert(mutationListen(), targets: [connection.id ?? -1]),
        )
        let clock = try #require(runtime.clock as? FakeClock)
        let pending = try #require(try await store.deliveries(for: stored.id ?? -1).first)
        clock.advance(to: pending.nextAttemptAt ?? clock.now)
        try await runtime.setConnectionEnabled(id: connection.id ?? -1, enabled: true)
        _ = await awaitBatches(adapter, count: 1)
        _ = await awaitDeliveries(store, listen: stored) { $0.first?.state == .retrying }
        let retrying = try #require(
            try await store.deliveries(for: stored.id ?? -1).first(where: { $0.state == .retrying }),
        )

        let edited = try await runtime.editListen(
            stored,
            to: ListenMetadata(title: "Corrected", artist: "Artist", album: "Album"),
            rememberAsRule: false,
        )
        let held = try #require(
            try await store.deliveries(for: stored.id ?? -1).first(where: { $0.state == .retrying }),
        )
        #expect(held.attempts == retrying.attempts)
        #expect(held.nextAttemptAt == retrying.nextAttemptAt)
        #expect(held.lastError == retrying.lastError)

        let next = try #require(held.nextAttemptAt)
        clock.advance(to: next)
        let batches = await awaitBatches(adapter, count: 2)
        #expect(batches.last?.first?.processed.title == "Corrected")
        #expect(batches.last?.first?.id == edited.id)
    }

    @Test func deliveredAbandonedAndZeroTargetRowsSurviveAnEditAndDisappearOnDelete() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let adapter = RecordingDeliveryAdapter(
            answers: [.results([.delivered(reference: "remote-1")])],
        )
        let runtime = makeMutationRuntime(store: store, adapters: [adapter])
        await runtime.start()
        let connection = try await runtime.link(kind: .listenBrainz, credential: "token")
        let clock = try #require(runtime.clock as? FakeClock)

        let abandonedListen = try #require(
            try await store.insert(mutationListen(title: "Abandoned"), targets: [connection.id ?? -1]),
        )
        let abandonedRow = try #require(
            try await store.deliveries(for: abandonedListen.id ?? -1).first,
        )
        try await store.abandon(
            abandonedRow.id,
            attempts: 1,
            lastAttemptAt: mutationBase,
            reason: "The service rejected this listen.",
        )
        let abandonedNow = try await store.deliveries(for: abandonedListen.id ?? -1).first
        #expect(abandonedNow?.state == .abandoned)

        let deliveredListen = try #require(
            try await store.insert(mutationListen(title: "Delivered"), targets: [connection.id ?? -1]),
        )
        clock.advance(to: deliveredListen.capturedAt)
        runtime.networkBecameAvailable()
        _ = await awaitBatches(adapter, count: 1)
        _ = await awaitDeliveries(store, listen: deliveredListen) { $0.first?.state == .delivered }
        let delivered = try #require(
            try await store.deliveries(for: deliveredListen.id ?? -1).first,
        )
        #expect(delivered.state == .delivered)
        #expect(delivered.serviceReference == "remote-1")

        let zeroTarget = try #require(try await store.insert(mutationListen(title: "No target")))

        let editedDelivered = try await runtime.editListen(
            deliveredListen,
            to: ListenMetadata(title: "Delivered edited", artist: "Artist"),
            rememberAsRule: false,
        )
        let editedAbandoned = try await runtime.editListen(
            abandonedListen,
            to: ListenMetadata(title: "Abandoned edited", artist: "Artist"),
            rememberAsRule: false,
        )
        let editedZero = try await runtime.editListen(
            zeroTarget,
            to: ListenMetadata(title: "No target edited", artist: "Artist"),
            rememberAsRule: false,
        )

        let deliveredAfter = try #require(
            try await store.deliveries(for: editedDelivered.id ?? -1).first,
        )
        #expect(deliveredAfter.state == .delivered)
        #expect(deliveredAfter.serviceReference == "remote-1")
        let abandonedAfter = try #require(
            try await store.deliveries(for: editedAbandoned.id ?? -1).first,
        )
        #expect(abandonedAfter.state == .abandoned)
        #expect(abandonedAfter.abandonedReason == "The service rejected this listen.")
        #expect(try await store.deliveries(for: editedZero.id ?? -1).isEmpty)
        #expect(await adapter.batches.count == 1)

        let batchesBeforeDelete = await adapter.batches.count
        try await runtime.deleteListen(editedDelivered)
        try await runtime.deleteListen(editedAbandoned)
        try await runtime.deleteListen(editedZero)
        #expect(try await store.count() == 0)
        #expect(try await store.deliveries(for: deliveredListen.id ?? -1).isEmpty)
        #expect(try await store.deliveries(for: abandonedListen.id ?? -1).isEmpty)
        #expect(await adapter.batches.count == batchesBeforeDelete)
        #expect(try await store.tombstoneCount() == 3)
    }

    @Test func aDeleteDuringAnInFlightSendDoesNotRecallIt() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let gate = DeliveryGate()
        let adapter = RecordingDeliveryAdapter(gate: gate)
        let runtime = makeMutationRuntime(store: store, adapters: [adapter])
        await runtime.start()
        let connection = try await runtime.link(kind: .listenBrainz, credential: "token")
        let stored = try #require(
            try await store.insert(mutationListen(), targets: [connection.id ?? -1]),
        )
        let clock = try #require(runtime.clock as? FakeClock)
        clock.advance(to: stored.capturedAt)
        runtime.networkBecameAvailable()
        #expect(await gate.waitUntilEntered(), "the gate is entered")

        try await runtime.deleteListen(stored)

        #expect(try await store.deliveries(for: stored.id ?? -1).isEmpty)
        #expect(runtime.state.pendingQueue.isEmpty)
        await gate.release()
        await turnMainActor(50)
        #expect(await adapter.batches.count == 1)
        #expect(try await store.count() == 0)
    }

    @Test func aCaptureConcurrentWithADeleteKeepsHistoryConsistent() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let seeded = try #require(try await store.insert(mutationListen(title: "Seeded")))
        let runtime = makeMutationRuntime(store: store)
        await runtime.start()
        let clock = try #require(runtime.clock as? FakeClock)
        let song = Track(
            title: "Captured",
            artist: "Artist",
            album: "Album",
            albumArtist: "Album Artist",
            duration: 30,
            bundleID: "com.apple.Music",
        )

        let deletion = Task { @MainActor in
            try await runtime.deleteListen(seeded)
        }
        let capture = Task { @MainActor in
            await replayThreshold(
                song,
                at: mutationBase.addingTimeInterval(600),
                on: runtime,
                clock: clock,
            )
        }
        try await deletion.value
        await capture.value

        #expect(try await store.count() == 1)
        #expect(runtime.state.historyCount == 1)
        #expect(runtime.state.listens.map(\.processed.title) == ["Captured"])
        #expect(try await store.tombstoneCount() == 1)
    }

    @Test func aStorageFailureLeavesTheRowAndPublishesNoSuccess() async throws {
        let database = try TemporaryDatabase()
        let base = try SQLiteListenStore(url: database.url)
        let stored = try #require(try await base.insert(mutationListen()))
        let runtime = makeMutationRuntime(store: FailingMutationStore(base))
        await runtime.start()

        do {
            _ = try await runtime.editListen(
                stored,
                to: ListenMetadata(title: "Corrected", artist: "Artist"),
                rememberAsRule: false,
            )
            Issue.record("an edit that failed to persist must throw")
        } catch {}
        #expect(runtime.state.failure?.stage == .storage)
        #expect(runtime.state.listens.first?.processed.title == "Song")
        #expect(try await base.page(limit: 10, before: nil).first?.processed.title == "Song")

        do {
            try await runtime.deleteListen(stored)
            Issue.record("a delete that failed to persist must throw")
        } catch {}
        #expect(runtime.state.failure?.stage == .storage)
        #expect(try await base.count() == 1)
    }

    @Test func repeatedRememberEditsMergeTheirReplacements() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let stored = try #require(try await store.insert(mutationListen()))
        let runtime = makeMutationRuntime(store: store)
        await runtime.start()

        let first = try await runtime.editListen(
            stored,
            to: ListenMetadata(
                title: "Corrected",
                artist: "Artist",
                album: "Album",
                albumArtist: "Album Artist",
            ),
            rememberAsRule: true,
        )
        _ = try await runtime.editListen(
            first,
            to: ListenMetadata(
                title: "Corrected",
                artist: "Artist",
                album: "Right",
                albumArtist: "Album Artist",
            ),
            rememberAsRule: true,
        )

        let rules = try await store.edits()
        #expect(rules.count == 1)
        let rule = try #require(rules.first)
        #expect(rule.replacement.track == "Corrected")
        #expect(rule.replacement.album == "Right")
        #expect(rule.replacement.artist == nil)
        #expect(rule.replacement.albumArtist == nil)

        runtime.stop()
        await store.close()
        let reopened = try SQLiteListenStore(url: database.url)
        let future = Track(
            title: "Song",
            artist: "Artist",
            album: "Album",
            albumArtist: "Album Artist",
            duration: 30,
            bundleID: "com.apple.Music",
        )
        let processed = try #require(
            try await MetadataPipeline.process(future, edits: reopened.edits()),
        )
        #expect(processed.title == "Corrected")
        #expect(processed.album == "Right")

        // The Edits page's own save is a full replacement, not the merged
        // history-edit behaviour.
        let fullReplace = SimpleEditRule(
            match: rule.match,
            replacement: .init(album: "Full replace"),
            savedAt: mutationBase,
        )
        let storedReplace = try await reopened.save(fullReplace)
        #expect(storedReplace.replacement.track == nil)
        #expect(storedReplace.replacement.album == "Full replace")
    }

    @Test func aFailedRuleValidationRollsBackTheEdit() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let stored = try #require(try await store.insert(mutationListen()))
        let invalidRule = SimpleEditRule(
            match: .init(track: "Song"),
            replacement: .init(),
            savedAt: mutationBase,
        )

        do {
            _ = try await store.editListen(
                id: stored.id ?? -1,
                to: ListenMetadata(title: "Must not persist", artist: "Artist"),
                remembering: invalidRule,
            )
            Issue.record("an invalid rule must roll the row edit back")
        } catch {}

        await store.close()
        let reopened = try SQLiteListenStore(url: database.url)
        let rows = try await reopened.page(limit: 10, before: nil)
        #expect(rows.first?.processed.title == "Song")
        #expect(try await reopened.edits().isEmpty)
    }

    @Test func aFailedDeleteRollsBackTheTombstoneAndKeepsRelatedState() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let connection = try await store.save(
            Connection(
                kind: .listenBrainz,
                endpoint: .listenBrainz,
                identity: "listener",
                isEnabled: true,
                authState: .signedIn,
                createdAt: mutationBase,
            ),
        )
        let stored = try #require(
            try await store.insert(mutationListen(), targets: [connection.id ?? -1]),
        )
        let key = ChartCacheKey(
            kind: .list,
            source: .local,
            chartType: .tracks,
            period: .allTime,
        )
        try await store.saveChartCache(
            ChartCacheEntry(savedAt: mutationBase, payload: Data("cached".utf8)),
            for: key,
        )
        try database.execute(
            """
            CREATE TRIGGER fail_listen_delete
            BEFORE DELETE ON listens
            BEGIN
                SELECT RAISE(ABORT, 'simulated delete failure');
            END;
            """,
        )

        do {
            try await store.deleteListen(id: stored.id ?? -1, at: mutationBase)
            Issue.record("the forced delete failure must throw")
        } catch {}

        #expect(try await store.count() == 1)
        #expect(try await store.deliveries(for: stored.id ?? -1).count == 1)
        #expect(try await store.chartCacheCount() == 1)
        #expect(try await store.tombstoneCount() == 0)

        await store.close()
        let reopened = try SQLiteListenStore(url: database.url)
        #expect(try await reopened.count() == 1)
        #expect(try await reopened.deliveries(for: stored.id ?? -1).count == 1)
        #expect(try await reopened.chartCacheCount() == 1)
        #expect(try await reopened.tombstoneCount() == 0)
    }

    @Test func aMutationAgainstAClosedStorePublishesNoChange() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let stored = try #require(try await store.insert(mutationListen()))
        let runtime = makeMutationRuntime(store: store)
        await runtime.start()
        await store.close()

        do {
            _ = try await runtime.editListen(
                stored,
                to: ListenMetadata(title: "Must not publish", artist: "Artist"),
                rememberAsRule: false,
            )
            Issue.record("editing a closed store must throw")
        } catch {}
        #expect(runtime.state.failure?.stage == .storage)
        #expect(runtime.state.listens.first?.processed.title == "Song")

        do {
            try await runtime.deleteListen(stored)
            Issue.record("deleting from a closed store must throw")
        } catch {}
        #expect(runtime.state.failure?.stage == .storage)
        #expect(runtime.state.listens.first?.processed.title == "Song")

        runtime.stop()
        let reopened = try SQLiteListenStore(url: database.url)
        #expect(try await reopened.count() == 1)
        #expect(try await reopened.page(limit: 10, before: nil).first?.processed.title == "Song")
    }

    @Test func anEditRacingACaptureKeepsBothRowsAndTheirDeliveries() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let adapter = RecordingDeliveryAdapter()
        let runtime = makeMutationRuntime(store: store, adapters: [adapter])
        await runtime.start()
        let connection = try await runtime.link(kind: .listenBrainz, credential: "token")
        let seeded = try #require(
            try await store.insert(mutationListen(), targets: [connection.id ?? -1]),
        )
        let clock = try #require(runtime.clock as? FakeClock)
        let capturedTrack = Track(
            title: "Captured",
            artist: "Artist",
            album: "Album",
            albumArtist: "Album Artist",
            duration: 30,
            bundleID: "com.apple.Music",
        )

        let edit = Task { @MainActor in
            try await runtime.editListen(
                seeded,
                to: ListenMetadata(title: "Edited", artist: "Artist", album: "Album"),
                rememberAsRule: false,
            )
        }
        let capture = Task { @MainActor in
            await replayThreshold(
                capturedTrack,
                at: mutationBase.addingTimeInterval(600),
                on: runtime,
                clock: clock,
            )
        }
        _ = try await edit.value
        await capture.value

        #expect(try await store.count() == 2)
        #expect(runtime.state.historyCount == 2)
        #expect(runtime.state.listens.contains { $0.processed.title == "Edited" })
        let captured = try #require(
            runtime.state.listens.first { $0.processed.title == "Captured" },
        )
        let deliveries = try await store.deliveries(
            forListenIDs: [seeded.id ?? -1, captured.id ?? -1],
        )
        #expect(deliveries.count == 2)
        #expect(Set(deliveries.map(\.listenID)) == Set([seeded.id ?? -1, captured.id ?? -1]))

        runtime.stop()
        await store.close()
        let reopened = try SQLiteListenStore(url: database.url)
        #expect(try await reopened.count() == 2)
        #expect(try await reopened.deliveries(
            forListenIDs: [seeded.id ?? -1, captured.id ?? -1],
        ).count == 2)
    }

    @Test func mutationsRefreshHistoryWhenCaptureIsOff() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let first = try #require(try await store.insert(mutationListen(title: "First")))
        let second = try #require(
            try await store.insert(mutationListen(title: "Second", start: mutationBase.addingTimeInterval(10))),
        )
        let runtime = makeMutationRuntime(store: store, scrobbling: false)
        await runtime.start()
        let day = Calendar.current.startOfDay(for: first.startedAt)

        try await runtime.deleteListen(first)
        #expect(runtime.state.historyDayCounts[day] == 1)
        #expect(runtime.state.historyCount == 1)

        let loved = ListenMetadata(
            title: "Loved",
            artist: "Artist",
            album: "Album",
            albumArtist: "Album Artist",
        )
        try await store.setFeedback(.loved, for: loved.identity, at: mutationBase)
        _ = try await runtime.editListen(
            second,
            to: loved,
            rememberAsRule: false,
        )
        #expect(runtime.state.feedback(for: loved.identity)?.score == .loved)
        #expect(runtime.state.listens.first?.processed == loved)
    }

    @Test func openingEditFromTrackHistoryKeepsItsDeliveryRows() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let connection = try await store.save(
            Connection(
                kind: .listenBrainz,
                endpoint: .listenBrainz,
                identity: "listener",
                isEnabled: true,
                authState: .signedIn,
                createdAt: mutationBase,
            ),
        )
        let oldest = try #require(
            try await store.insert(
                mutationListen(title: "Oldest"),
                targets: [connection.id ?? -1],
            ),
        )
        _ = try await store.insert(mutationListen(title: "Middle", start: mutationBase.addingTimeInterval(10)))
        _ = try await store.insert(mutationListen(title: "Newest", start: mutationBase.addingTimeInterval(20)))
        let runtime = makeMutationRuntime(store: store, pageSize: 1)
        await runtime.start()
        #expect(runtime.state.listens.map(\.processed.title) == ["Newest"])

        await openTrackDetail(runtime, oldest)
        #expect(runtime.state.entityDetail?.track?.listens.first?.id == oldest.id)
        #expect(runtime.state.deliveries(for: oldest).count == 1)

        runtime.state.requestListenEdit(oldest)
        runtime.closeEntityDetail()
        await runtime.reloadDeliveryState()

        #expect(runtime.state.entityDetail?.track == nil)
        #expect(runtime.state.deliveries(for: oldest).count == 1)
    }

    @Test func aRememberedAlbumCorrectionAppliesToFuturePlaysOnThatAlbumOnly() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let first = try #require(try await store.insert(mutationListen(album: "Wrong")))
        let second = try #require(
            try await store.insert(mutationListen(album: "Wrong", start: mutationBase.addingTimeInterval(10))),
        )
        let runtime = makeMutationRuntime(store: store)
        await runtime.start()
        let clock = try #require(runtime.clock as? FakeClock)

        _ = try await runtime.editListen(
            first,
            to: ListenMetadata(
                title: "Song",
                artist: "Artist",
                album: "Right",
                albumArtist: "Album Artist",
            ),
            rememberAsRule: true,
        )

        let rules = try await store.edits()
        #expect(rules.count == 1)
        let rule = try #require(rules.first)
        #expect(rule.match.track == "Song")
        #expect(rule.match.artist == "Artist")
        #expect(rule.match.album == "Wrong")
        #expect(rule.match.albumArtist == "Album Artist")
        #expect(rule.replacement.track == nil)
        #expect(rule.replacement.artist == nil)
        #expect(rule.replacement.album == "Right")
        #expect(rule.replacement.albumArtist == nil)
        #expect(try await store.page(limit: 10, before: nil)
            .first(where: { $0.id == second.id })?.processed.album == "Wrong")

        await replayThreshold(
            Track(
                title: "Song",
                artist: "Artist",
                album: "Wrong",
                albumArtist: "Album Artist",
                duration: 30,
                bundleID: "com.apple.Music",
            ),
            at: mutationBase.addingTimeInterval(1_000),
            on: runtime,
            clock: clock,
        )
        await replayThreshold(
            Track(
                title: "Song",
                artist: "Artist",
                album: "Other",
                albumArtist: "Album Artist",
                duration: 30,
                bundleID: "com.apple.Music",
            ),
            at: mutationBase.addingTimeInterval(2_000),
            on: runtime,
            clock: clock,
        )

        let sameAlbum = try #require(
            runtime.state.listens.first { $0.startedAt == mutationBase.addingTimeInterval(1_000) },
        )
        let otherAlbum = try #require(
            runtime.state.listens.first { $0.startedAt == mutationBase.addingTimeInterval(2_000) },
        )
        #expect(sameAlbum.processed.album == "Right")
        #expect(otherAlbum.processed.album == "Other")
    }

    @Test func oneEditLeavesDifferentMetadataOnDifferentServices() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let lastFM = RecordingDeliveryAdapter(kind: .lastFM)
        let listenBrainz = RecordingDeliveryAdapter(kind: .listenBrainz)
        let runtime = makeMutationRuntime(store: store, adapters: [lastFM, listenBrainz])
        await runtime.start()
        let fmConnection = try await runtime.link(kind: .lastFM, credential: "key")
        let lbConnection = try await runtime.link(kind: .listenBrainz, credential: "token")
        try await runtime.setConnectionEnabled(id: lbConnection.id ?? -1, enabled: false)
        let stored = try #require(
            try await store.insert(
                mutationListen(),
                targets: [fmConnection.id ?? -1, lbConnection.id ?? -1],
            ),
        )
        let clock = try #require(runtime.clock as? FakeClock)
        clock.advance(to: stored.capturedAt)
        runtime.networkBecameAvailable()
        _ = await awaitBatches(lastFM, count: 1)
        _ = await awaitDeliveries(store, listen: stored) { $0.first?.state == .delivered }
        #expect(try await store.deliveries(for: stored.id ?? -1)
            .contains(where: { $0.connectionID == lbConnection.id && $0.state == .waiting }))

        _ = try await runtime.editListen(
            stored,
            to: ListenMetadata(title: "Corrected", artist: "Artist", album: "Album"),
            rememberAsRule: false,
        )
        clock.advance(to: mutationBase.addingTimeInterval(60))
        try await runtime.setConnectionEnabled(id: lbConnection.id ?? -1, enabled: true)
        _ = await awaitBatches(listenBrainz, count: 1)

        #expect(await lastFM.batches.first?.first?.processed.title == "Song")
        #expect(await listenBrainz.batches.first?.first?.processed.title == "Corrected")
    }

    @Test func aLocalMutationMakesNoServiceWriteBackRequest() async throws {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let transport = ScriptedTransport([
            listenBrainzValidResponse(),
            HTTPResponse(statusCode: 200, body: Data(#"{"status":"ok"}"#.utf8)),
        ])
        let runtime = makeMutationRuntime(
            store: store,
            adapters: [ListenBrainzAdapter(transport: transport)],
        )
        await runtime.start()
        let connection = try await runtime.link(kind: .listenBrainz, credential: "token")
        let stored = try #require(
            try await store.insert(mutationListen(), targets: [connection.id ?? -1]),
        )
        let clock = try #require(runtime.clock as? FakeClock)
        clock.advance(to: stored.capturedAt)
        runtime.networkBecameAvailable()
        _ = await awaitRequests(transport, count: 2)
        _ = await awaitDeliveries(store, listen: stored) { $0.first?.state == .delivered }
        #expect(await transport.requests.count == 2)

        let edited = try await runtime.editListen(
            stored,
            to: ListenMetadata(title: "Corrected", artist: "Artist"),
            rememberAsRule: false,
        )
        #expect(await transport.requests.count == 2, "an edit is local only")

        try await runtime.deleteListen(edited)
        #expect(await transport.requests.count == 2, "a delete is local only")
        #expect(try await store.deliveries(for: stored.id ?? -1).isEmpty)
    }

    @Test func theNoticesNameEveryServiceStateAndTheInFlightLimit() {
        let waiting = Delivery(
            id: 1,
            listenID: 1,
            connectionID: 1,
            serviceKind: .lastFM,
            state: .waiting,
            attempts: 0,
        )
        let delivered = Delivery(
            id: 2,
            listenID: 1,
            connectionID: 2,
            serviceKind: .listenBrainz,
            state: .delivered,
            attempts: 1,
        )
        let abandoned = Delivery(
            id: 3,
            listenID: 1,
            connectionID: 3,
            serviceKind: .libreFM,
            state: .abandoned,
            attempts: 1,
        )
        let listen = mutationListen()

        let edit = ListenMutationNoticeBuilder.edit(
            deliveries: [waiting, delivered, abandoned],
            connections: [],
        )
        #expect(edit.body == "Changes stay on this Mac.")
        #expect(edit.serviceLines == [
            "Waiting for Last.fm: the next attempt will use these values.",
            "Delivered to ListenBrainz: that copy stays.",
            "Not delivered to Libre.fm: unchanged.",
        ])
        #expect(edit.footer == ListenMutationNoticeBuilder.editFooter)

        let delete = ListenMutationNoticeBuilder.delete(
            listen: listen,
            deliveries: [waiting, delivered, abandoned],
            connections: [],
        )
        #expect(delete.title == "Delete “Song”?")
        #expect(delete.body == "This listen will be removed from this Mac's history.")
        #expect(delete.serviceLines[0] == "Waiting for Last.fm: that delivery will be discarded. "
            + "A send already under way may still arrive.")
        #expect(delete.serviceLines[1] == "Delivered to ListenBrainz: that copy stays.")
        #expect(delete.serviceLines[2] == "Not delivered to Libre.fm: unchanged.")
        #expect(delete.footer == ListenMutationNoticeBuilder.deleteFooter)

        let noTargets = ListenMutationNoticeBuilder.delete(
            listen: listen,
            deliveries: [],
            connections: [],
        )
        #expect(noTargets.serviceLines == ["No service received this listen."])
    }
}
