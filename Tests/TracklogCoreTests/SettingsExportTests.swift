import Foundation
import Testing
@testable import TracklogCore

@Suite("Settings export")
@MainActor
struct SettingsExportTests: CaptureTestHelpers {
    private let pauseSentinel = Date(timeIntervalSince1970: 9_999_999)
    private let connectionSentinel = "EXCLUDED-connection-identity"
    private let credentialSentinel = "EXCLUDED-credential-token"
    private let listenSentinel = "EXCLUDED-listen-title"
    private let deliverySentinel = "EXCLUDED-delivery-error"
    private let artworkSentinel = "EXCLUDED-artwork-hash"
    private let feedbackSentinel = "EXCLUDED-feedback-identity"

    private func seededStore(
        credentials: MemoryCredentialStore,
    ) async throws -> (TemporaryDatabase, SQLiteListenStore) {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)

        let allowed = SeenApp(bundleID: "com.example.AllowedPlayer", isAllowed: true)
        let denied = SeenApp(bundleID: "com.example.DeniedPlayer", isAllowed: false)
        for app in [allowed, denied] {
            try await store.recordSeen(app.bundleID)
            try await store.setAllowed(app.bundleID, allowed: app.isAllowed)
        }

        _ = try await store.save(
            simpleEditRule(
                match: .init(track: "RAW Track", artist: "RAW Artist"),
                replace: .init(track: "Edited Track", album: ""),
                savedAt: base.addingTimeInterval(10),
            ),
        )
        _ = try await store.save(
            simpleEditRule(
                match: .init(album: "RAW Album"),
                replace: .init(albumArtist: "Edited Album Artist"),
                savedAt: base.addingTimeInterval(20),
            ),
        )
        _ = try await store.save(
            blockRule(
                track: "Blocked Track",
                artist: "Blocked Artist",
                savedAt: base.addingTimeInterval(30),
            ),
        )
        _ = try await store.save(
            blockRule(
                album: "Blocked Album",
                savedAt: base.addingTimeInterval(40),
            ),
        )

        try await seedExcludedData(store: store, credentials: credentials)
        return (database, store)
    }

    private func seedExcludedData(
        store: SQLiteListenStore,
        credentials: MemoryCredentialStore,
    ) async throws {
        let connection = try await store.save(
            Connection(
                kind: .listenBrainz,
                endpoint: .listenBrainz,
                identity: connectionSentinel,
                createdAt: base,
            ),
        )
        try await store.setCurrentConnectionID(connection.id)

        let listen = Listen(
            raw: ListenMetadata(
                title: listenSentinel,
                artist: "EXCLUDED-listen-artist",
                album: "EXCLUDED-listen-album",
            ),
            processed: ListenMetadata(title: listenSentinel, artist: "EXCLUDED-listen-artist"),
            bundleID: "com.apple.Music",
            duration: 200,
            playedDuration: 200,
            startedAt: base,
            capturedAt: base,
        )
        _ = try await store.insert(listen, targets: [connection.id ?? -1])
        let stored = try #require(try await store.recent(limit: 1).first)
        if let deliveryID = try await store.pendingDeliveries().first?.delivery.id {
            try await store.markFailed(
                deliveryID,
                attempts: 1,
                at: base,
                nextAttemptAt: base.addingTimeInterval(60),
                error: deliverySentinel,
            )
        }

        let identity = stored.raw.identity
        try await store.attachArtwork(
            StoredArtwork(
                hash: artworkSentinel,
                data: Data([1, 2, 3]),
                pixelWidth: 1,
                pixelHeight: 1,
            ),
            toTrack: identity,
        )
        try await store.setFeedback(.loved, for: feedbackSentinel, at: base)
        try await credentials.saveCredential(credentialSentinel, forConnection: connection.id ?? -1)
    }

    private func settings() -> CaptureSettings {
        CaptureSettings(
            scrobblingEnabled: true,
            nowPlayingEnabled: false,
            pausedUntil: pauseSentinel,
            minimumDuration: 90,
        )
    }

    @Test func theRuntimeEntryPointExportsEverySavedRuleAndNoExcludedData() async throws {
        let credentials = MemoryCredentialStore()
        let (database, store) = try await seededStore(credentials: credentials)
        defer { withExtendedLifetime(database) {} }
        let runtime = CaptureRuntime(
            clock: FakeClock(base),
            source: ReplayedNowPlaying(),
            store: store,
            allowlist: store,
            edits: store,
            blocks: store,
            credentials: credentials,
            settings: settings(),
        )

        // Deliberately do not start the runtime: the published page arrays stay
        // empty while the store already holds the durable rows.
        #expect(runtime.state.simpleEdits.isEmpty)
        #expect(runtime.state.blocks.isEmpty)

        let export = try await runtime.makeSettingsExport()
        let data = try export.encoded()
        let text = try #require(String(data: data, encoding: .utf8))

        #expect(export.version == 1)
        #expect(export.settings.scrobblingEnabled)
        #expect(!export.settings.nowPlayingEnabled)
        #expect(export.settings.minimumDuration == 90)
        #expect(export.apps.contains(SettingsExportApp(bundleID: "com.example.AllowedPlayer", isAllowed: true)))
        #expect(export.apps.contains(SettingsExportApp(bundleID: "com.example.DeniedPlayer", isAllowed: false)))
        #expect(export.simpleEdits.count == 2)
        #expect(export.simpleEdits.contains { $0.match.track == "RAW Track" && $0.replacement.track == "Edited Track" })
        #expect(export.blocks.count == 2)
        #expect(export.blocks.contains { $0.track == "Blocked Track" && $0.artist == "Blocked Artist" })
        #expect(export.blocks.contains { $0.album == "Blocked Album" && $0.track.isEmpty })

        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["version", "settings", "apps", "simple_edits", "blocks"])
        let settingsObject = try #require(object["settings"] as? [String: Any])
        #expect(Set(settingsObject.keys) == ["scrobbling_enabled", "now_playing_enabled", "minimum_duration"])
        let firstEdit = try #require((object["simple_edits"] as? [[String: Any]])?.first)
        #expect(Set(firstEdit.keys) == ["match", "replacement"])
        #expect(Set((firstEdit["match"] as? [String: Any])?.keys.map(\.self) ?? [])
            == ["track", "artist", "album", "album_artist"])
        let firstBlock = try #require((object["blocks"] as? [[String: Any]])?.first)
        #expect(Set(firstBlock.keys) == ["track", "artist", "album", "album_artist"])

        for sentinel in [
            connectionSentinel, credentialSentinel, listenSentinel, deliverySentinel,
            artworkSentinel, feedbackSentinel, pauseSentinel.description,
        ] {
            #expect(!text.contains(sentinel), "\(sentinel) leaked into the export")
        }
        #expect(!text.contains("current_connection"))
        #expect(!text.contains("paused_until"))
        #expect(!text.contains("9999999"))
        #expect(!text.contains("credentials"))
        #expect(!text.contains("deliveries"))
        #expect(!text.contains("artwork"))
    }

    @Test func aStalePageLoadCannotShrinkTheExport() async throws {
        let (database, store) = try await seededStore(credentials: MemoryCredentialStore())
        defer { withExtendedLifetime(database) {} }
        let runtime = CaptureRuntime(
            clock: FakeClock(base),
            source: ReplayedNowPlaying(),
            store: store,
            allowlist: store,
            edits: store,
            blocks: store,
            settings: settings(),
        )
        await runtime.start()
        let loadedCount = runtime.state.simpleEdits.count

        _ = try await store.save(
            simpleEditRule(
                match: .init(track: "Added after the page loaded"),
                replace: .init(artist: "Fresh value"),
                savedAt: base.addingTimeInterval(100),
            ),
        )
        #expect(runtime.state.simpleEdits.count == loadedCount)

        let export = try await runtime.makeSettingsExport()
        #expect(export.simpleEdits.contains {
            $0.match.track == "Added after the page loaded" && $0.replacement.artist == "Fresh value"
        })
    }

    @Test func aReadFailureIsSurfacedAndNothingIsWritten() async throws {
        let (database, store) = try await seededStore(credentials: MemoryCredentialStore())
        defer { withExtendedLifetime(database) {} }
        let runtime = CaptureRuntime(
            clock: FakeClock(base),
            source: ReplayedNowPlaying(),
            store: store,
            allowlist: store,
            edits: store,
            blocks: store,
            settings: settings(),
        )
        await store.close()

        do {
            _ = try await runtime.makeSettingsExport()
            Issue.record("the export should have failed instead of returning a partial snapshot")
        } catch let failure as SettingsExportReadFailure {
            #expect(failure.section == "app allowlist")
            #expect(!failure.message.isEmpty)
        }
    }

    @Test func aFailingRuleReadIsSurfacedWithItsSection() async throws {
        let (database, store) = try await seededStore(credentials: MemoryCredentialStore())
        defer { withExtendedLifetime(database) {} }
        let runtime = CaptureRuntime(
            clock: FakeClock(base),
            source: ReplayedNowPlaying(),
            store: store,
            allowlist: store,
            edits: FailingSimpleEditStore(),
            blocks: store,
            settings: settings(),
        )

        do {
            _ = try await runtime.makeSettingsExport()
            Issue.record("the export should have failed instead of returning a partial snapshot")
        } catch let failure as SettingsExportReadFailure {
            #expect(failure.section == "simple edits")
        }
    }

    @Test func aFutureSectionDecodesAndReencodesWithoutAMigration() throws {
        let export = SettingsExport(
            settings: SettingsExportSettings(scrobblingEnabled: true, nowPlayingEnabled: true, minimumDuration: 30),
            apps: [SettingsExportApp(bundleID: "com.example.Music", isAllowed: true)],
            simpleEdits: [],
            blocks: [],
        )
        let data = try export.encoded()
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["regex_rules"] = []

        let future = try JSONSerialization.data(withJSONObject: object)
        let decoded = try SettingsExport.decode(future)
        #expect(decoded.version == 1)
        #expect(decoded.apps == export.apps)
        #expect(decoded.simpleEdits.isEmpty)
        #expect(decoded.blocks.isEmpty)
    }
}

private actor FailingSimpleEditStore: SimpleEditStore {
    func edits() async throws -> [SimpleEditRule] {
        throw DatabaseError.unavailable("the edits table is unavailable")
    }

    func save(_: SimpleEditRule) async throws -> SimpleEditRule {
        throw DatabaseError.unavailable("the edits table is unavailable")
    }

    func deleteEdit(id _: Int64) async throws {
        throw DatabaseError.unavailable("the edits table is unavailable")
    }
}
