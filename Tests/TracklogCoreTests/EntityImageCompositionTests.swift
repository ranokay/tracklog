import Foundation
import Testing
@testable import TracklogCore

// swiftlint:disable file_length

@Suite("Entity images")
@MainActor
// swiftlint:disable:next type_body_length
struct EntityImageCompositionTests {
    private func artistRequest(_ name: String = "Blondie") throws -> EntityRequest {
        try #require(EntityRequest.artist(name: name))
    }

    private func albumRequest(
        _ album: String = "Parallel Lines",
        artist: String = "Blondie",
    ) throws -> EntityRequest {
        try #require(EntityRequest.album(album: album, artist: artist))
    }

    private func trackRequest() throws -> EntityRequest {
        try #require(EntityRequest.track(title: "Heart of Glass", artist: "Blondie"))
    }

    private func linkLastFM(_ composition: EntityTestComposition) async throws {
        _ = try await composition.runtime.linkVerified(
            kind: .lastFM,
            credential: "session",
            identity: ServiceIdentity(name: "listener"),
        )
    }

    private func image(
        red: CGFloat = 0.2,
        green: CGFloat = 0.4,
        blue: CGFloat = 0.6,
    ) throws -> Data {
        try #require(testImageData(red: red, green: green, blue: blue))
    }

    private func saveArtistOverride(
        _ composition: EntityTestComposition,
        name: String = "Blondie",
        data: Data,
    ) async throws -> ImageOverride {
        let request = try artistRequest(name)
        try await composition.runtime.saveImageOverride(
            kind: .artist,
            key: request.key,
            title: request.title,
            subtitle: request.subtitle,
            data: data,
        )
        return try #require(composition.state.imageOverrides.first)
    }

    // MARK: - Overrides

    @Test func overridesSurviveRestartUnlinkDeletionAndStayOutOfExport() async throws {
        let database = try TemporaryDatabase()
        let composition = try await entityComposition(database: database) { _ in
            entityLastFMArtistInfo()
        }
        try await seedEntityHistory(composition.store)
        try await linkLastFM(composition)
        let override = try await saveArtistOverride(composition, data: image())
        #expect(try await composition.store.imageOverrideCount() == 1)

        composition.runtime.stop()
        await composition.store.close()

        let reopened = try await entityComposition(database: database) { _ in
            entityLastFMArtistInfo()
        }
        try await linkLastFM(reopened)
        await reopened.runtime.loadImageOverrides()
        #expect(reopened.state.imageOverrides.count == 1)
        #expect(reopened.state.imageOverrides.first?.key == override.key)
        #expect(try await reopened.store.artwork(for: override.artworkHash) != nil)

        let connection = try #require(reopened.state.currentConnection)
        let id = try #require(connection.id)
        _ = try await reopened.runtime.unlinkConnection(id: id)
        #expect(try await reopened.store.imageOverride(kind: .artist, key: override.key) != nil)

        let listen = try #require(reopened.state.listens.first)
        try await reopened.runtime.deleteListen(listen)
        #expect(try await reopened.store.imageOverride(kind: .artist, key: override.key) != nil)

        let export = try await reopened.runtime.makeSettingsExport()
        let text = try String(data: export.encoded(), encoding: .utf8) ?? ""
        #expect(!text.contains(override.key))
        #expect(!text.contains(override.artworkHash))
    }

    @Test func removingOrReplacingAnOverrideDeletesItsBytes() async throws {
        let database = try TemporaryDatabase()
        let composition = try await entityComposition(database: database) { _ in
            entityLastFMArtistInfo()
        }
        try await linkLastFM(composition)
        let first = try await saveArtistOverride(composition, data: image(red: 0.9))
        let second = try await saveArtistOverride(composition, data: image(blue: 0.9))

        #expect(first.artworkHash != second.artworkHash)
        #expect(try await composition.store.artwork(for: first.artworkHash) == nil)
        #expect(try await composition.store.artwork(for: second.artworkHash) != nil)

        try await composition.runtime.removeImageOverride(kind: .artist, key: second.key)
        #expect(try await composition.store.imageOverrideCount() == 0)
        #expect(try await composition.store.artwork(for: second.artworkHash) == nil)

        await composition.store.close()
        let reopened = try SQLiteListenStore(url: database.url)
        #expect(try await reopened.artwork(for: first.artworkHash) == nil)
        #expect(try await reopened.artwork(for: second.artworkHash) == nil)
        await reopened.close()
    }

    @Test func aListenReferencedBlobSurvivesOverrideRemoval() async throws {
        let composition = try await entityComposition { _ in
            entityLastFMArtistInfo()
        }
        let listen = try #require(
            try await composition.store.insert(
                entityListen(
                    title: "Heart of Glass",
                    artist: "Blondie",
                    album: "Parallel Lines",
                    start: historyBase,
                ),
            ),
        )
        let bytes = try image()
        let stored = try #require(ArtworkNormalizer.normalize(bytes))
        try await composition.store.attachArtwork(stored, toTrack: listen.raw.identity)
        try await linkLastFM(composition)

        let override = try await saveArtistOverride(composition, data: bytes)
        #expect(override.artworkHash == stored.hash,
                "the same bytes share one content-addressed row")
        try await composition.runtime.removeImageOverride(kind: .artist, key: override.key)
        #expect(try await composition.store.artwork(for: stored.hash) != nil,
                "a listen still shows the captured cover")
    }

    @Test func anUnreadableOverrideFallsBackToNeutralAndStaysRemovable() async throws {
        let database = try TemporaryDatabase()
        let composition = try await entityComposition(database: database) { request in
            if formParameters(request)["method"] == "artist.getInfo" {
                return entityLastFMArtistInfo()
            }
            return entityLastFMError(3, message: "Invalid Method")
        }
        try await seedEntityHistory(composition.store)
        try await linkLastFM(composition)
        let override = try await saveArtistOverride(composition, data: image())
        try await composition.store.deleteArtworkRowForTest(hash: override.artworkHash)
        composition.runtime.stop()
        await composition.store.close()

        let reopened = try await entityComposition(database: database) { request in
            if formParameters(request)["method"] == "artist.getInfo" {
                return entityLastFMArtistInfo()
            }
            return entityLastFMError(3, message: "Invalid Method")
        }
        try await linkLastFM(reopened)
        await reopened.runtime.loadImageOverrides()
        try await reopened.runtime.openEntityDetail(artistRequest())
        #expect(await waitForUnreadableOverride(reopened.state))
        let detail = try #require(reopened.state.entityDetail)
        #expect(detail.overrideIsUnreadable)
        #expect(detail.overrideHash == override.artworkHash)
        #expect(detail.canRemoveImage)
        #expect(detail.imageSource == .neutral, "an unreadable override owns the neutral sleeve")
        #expect(detail.local.count == 3, "the local section still finishes")
        #expect(!detail.isLoadingLocal)
        #expect(await reopened.transport.itunesRequests().isEmpty,
                "an override means no Apple request, readable or not")
        #expect(await reopened.transport.requests(pathEndingWith: "artist.jpg").isEmpty)

        try await reopened.runtime.removeImageOverride(kind: .artist, key: override.key)
        #expect(try await reopened.store.imageOverrideCount() == 0)
        #expect(try await reopened.store.artwork(for: override.artworkHash) == nil)
    }

    @Test func anUndecodableOverrideAlsoOwnsTheNeutralSleeve() async throws {
        let database = try TemporaryDatabase()
        let composition = try await entityComposition(
            database: database,
            handler: artistSearchHandler([
                ("1012882", "Blondie", "https://images.example/artist.jpg"),
            ]),
        )
        try await linkLastFM(composition)
        let override = try await saveArtistOverride(composition, data: image())
        try await composition.store.replaceArtworkDataForTest(
            hash: override.artworkHash,
            data: Data("not an image".utf8),
        )
        composition.runtime.stop()
        await composition.store.close()

        let reopened = try await entityComposition(
            database: database,
            handler: artistSearchHandler([
                ("1012882", "Blondie", "https://images.example/artist.jpg"),
            ]),
        )
        try await linkLastFM(reopened)
        await reopened.runtime.loadImageOverrides()
        try await reopened.runtime.openEntityDetail(artistRequest())
        #expect(await waitForUnreadableOverride(reopened.state))
        #expect(reopened.state.entityDetail?.imageSource == .neutral)
        #expect(await reopened.transport.itunesRequests().isEmpty)
    }

    @Test func anUnreadableAlbumOverrideBeatsACapturedCoverAndTheServiceImage() async throws {
        let database = try TemporaryDatabase()
        let capturedBytes = try image(red: 0.9)
        let captured = try #require(ArtworkNormalizer.normalize(capturedBytes))
        let composition = try await entityComposition(database: database) { request in
            if formParameters(request)["method"] == "album.getInfo" {
                return entityLastFMAlbumInfo(image: "https://images.example/album.jpg")
            }
            return entityLastFMError(3, message: "Invalid Method")
        }
        let listen = try #require(
            try await composition.store.insert(
                entityListen(
                    title: "Heart of Glass",
                    artist: "Blondie",
                    album: "Parallel Lines",
                    start: historyBase,
                ),
            ),
        )
        try await composition.store.attachArtwork(captured, toTrack: listen.raw.identity)
        try await linkLastFM(composition)
        let album = try albumRequest()
        try await composition.runtime.saveImageOverride(
            kind: .album,
            key: album.key,
            title: album.title,
            subtitle: album.subtitle,
            data: image(blue: 0.8),
        )
        let override = try #require(composition.state.imageOverrides.first { $0.kind == .album })
        try await composition.store.replaceArtworkDataForTest(
            hash: override.artworkHash,
            data: Data("not an image".utf8),
        )
        composition.runtime.stop()
        await composition.store.close()

        let reopened = try await entityComposition(database: database) { request in
            if formParameters(request)["method"] == "album.getInfo" {
                return entityLastFMAlbumInfo(image: "https://images.example/album.jpg")
            }
            return entityLastFMError(3, message: "Invalid Method")
        }
        try await linkLastFM(reopened)
        await reopened.runtime.loadImageOverrides()
        try await reopened.runtime.openEntityDetail(albumRequest())
        #expect(await waitForUnreadableOverride(reopened.state))
        #expect(reopened.state.entityDetail?.imageSource == .neutral,
                "the captured cover is below an unreadable override")
        #expect(await reopened.transport.requests(pathEndingWith: "album.jpg").isEmpty)

        let chartItem = ChartItem(
            rank: 1,
            title: "Parallel Lines",
            subtitle: "Blondie",
            count: 1,
            identityKey: "chart",
        )
        #expect(reopened.state.hasImageOverride(for: chartItem, type: .albums))
        #expect(reopened.state.imageOverrideData(for: chartItem, type: .albums) == nil)
        let paletteRow = CatalogueRow(
            group: .albums,
            title: "Parallel Lines",
            subtitle: "Blondie",
            playbackQuery: "",
            pageURL: nil,
        )
        #expect(reopened.state.hasImageOverride(for: paletteRow))
        #expect(reopened.state.imageOverrideData(for: paletteRow) == nil)
    }

    @Test func theImageFileReaderRefusesEmptyOversizedAndInaccessibleFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracklog-image-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let empty = directory.appendingPathComponent("empty.png")
        try Data().write(to: empty)
        #expect(ImageOverrideFileReader.read(empty) == .failure(.unreadable))

        let oversized = directory.appendingPathComponent("oversized.png")
        try Data(repeating: 0, count: 32).write(to: oversized)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(ImageOverridePolicy.maximumSourceBytes + 1))
        try handle.close()
        #expect(ImageOverrideFileReader.read(oversized) == .failure(.tooLarge))

        let inaccessible = directory.appendingPathComponent("missing.png")
        #expect(ImageOverrideFileReader.read(inaccessible) == .failure(.unreadable))

        let valid = directory.appendingPathComponent("valid.png")
        try #require(testImageData()).write(to: valid)
        if case let .failure(error) = ImageOverrideFileReader.read(valid) {
            Issue.record("a valid image failed: \(error)")
        }
    }

    @Test func deactivatingStopsAnInFlightOverrideLoad() async throws {
        let gate = ChartHoldGate()
        await gate.startHolding()
        let database = try TemporaryDatabase()
        let base = try SQLiteListenStore(url: database.url)
        let holding = HoldingOverridesStore(base, gate: gate)
        let state = TracklogAppState()
        let runtime = CaptureRuntime(
            state: state,
            clock: FakeClock(historyBase),
            source: ReplayedNowPlaying(),
            store: holding,
            allowlist: InMemoryAppAllowlist(),
            credentials: MemoryCredentialStore(),
            serviceAdapters: [],
            settings: CaptureSettings(scrobblingEnabled: false),
        )
        await runtime.start()
        #expect(await gate.waitUntilEntered(1), "the activation override read is held")

        runtime.stop()
        await gate.release()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(state.imageOverrides.isEmpty,
                "a deactivated activation load publishes nothing")
    }

    @Test func removingAnAlbumOverrideRestoresTheServiceImage() async throws {
        let composition = try await entityComposition { request in
            if formParameters(request)["method"] == "album.getInfo" {
                return entityLastFMAlbumInfo(image: "https://images.example/album.jpg")
            }
            if request.url.path.hasSuffix("album.jpg") {
                return entityImageResponse(try? testImageData(red: 0.4, green: 0.3, blue: 0.8))
            }
            return entityLastFMError(3, message: "Invalid Method")
        }
        _ = try await composition.store.insert(
            entityListen(
                title: "Dreaming",
                artist: "Blondie",
                album: "Eat to the Beat",
                start: historyBase,
            ),
        )
        try await linkLastFM(composition)
        let album = try albumRequest("Eat to the Beat", artist: "Blondie")
        await composition.runtime.openEntityDetail(album)
        #expect(await waitForEntityImage(composition.state, source: .service))
        #expect(await composition.transport.requests(pathEndingWith: "album.jpg").count == 1)

        let overrideBytes = try image(red: 0.9)
        try await composition.runtime.saveImageOverride(
            kind: .album,
            key: album.key,
            title: album.title,
            subtitle: album.subtitle,
            data: overrideBytes,
        )
        #expect(composition.state.entityDetail?.imageSource == .override)

        try await composition.runtime.removeImageOverride(kind: .album, key: album.key)
        #expect(await waitForEntityImage(composition.state, source: .service))
        #expect(await composition.transport.requests(pathEndingWith: "album.jpg").count == 1,
                "the service image already downloaded is restored without a new request")
    }

    @Test func removingAnAlbumOverrideStartsTheServiceImageThatArrivedUnderIt() async throws {
        let composition = try await entityComposition { request in
            if formParameters(request)["method"] == "album.getInfo" {
                return entityLastFMAlbumInfo(image: "https://images.example/album.jpg")
            }
            if request.url.path.hasSuffix("album.jpg") {
                return entityImageResponse(try? testImageData(red: 0.4, green: 0.3, blue: 0.8))
            }
            return entityLastFMError(3, message: "Invalid Method")
        }
        _ = try await composition.store.insert(
            entityListen(
                title: "Dreaming",
                artist: "Blondie",
                album: "Eat to the Beat",
                start: historyBase,
            ),
        )
        try await linkLastFM(composition)
        let album = try albumRequest("Eat to the Beat", artist: "Blondie")
        // The override is already in place when the page opens, so the
        // service image is never fetched while it is up.
        let overrideBytes = try image(red: 0.9)
        try await composition.runtime.saveImageOverride(
            kind: .album,
            key: album.key,
            title: album.title,
            subtitle: album.subtitle,
            data: overrideBytes,
        )
        await composition.runtime.openEntityDetail(album)
        #expect(composition.state.entityDetail?.imageSource == .override)
        #expect(await composition.transport.requests(pathEndingWith: "album.jpg").isEmpty,
                "the override is above the service image")

        try await composition.runtime.removeImageOverride(kind: .album, key: album.key)
        #expect(await waitForEntityImage(composition.state, source: .service),
                "removing the override reaches the service image")
        #expect(await composition.transport.requests(pathEndingWith: "album.jpg").count == 1,
                "the released album page downloads the service image once")
    }

    @Test func aSuccessfulSaveClearsItsOwnDraft() async throws {
        let composition = try await entityComposition { _ in entityLastFMArtistInfo() }
        let request = try artistRequest()
        composition.runtime.beginImageOverride(request)
        #expect(composition.state.imageOverrideDraft?.key == request.key)
        let bytes = try image()

        try await composition.runtime.saveImageOverride(
            kind: request.kind,
            key: request.key,
            title: request.title,
            subtitle: request.subtitle,
            data: bytes,
        )

        #expect(composition.state.imageOverrideDraft == nil)
    }

    /// The picker captures the entity before the panel runs. The page leaving
    /// during the off-main read clears the draft, but the save that follows
    /// still targets the entity the file was chosen for.
    @Test func anExplicitSaveSurvivesTheDraftBeingClearedFirst() async throws {
        let composition = try await entityComposition { _ in entityLastFMArtistInfo() }
        let request = try artistRequest()
        composition.runtime.beginImageOverride(request)
        composition.runtime.clearImageOverrideDraft()
        #expect(composition.state.imageOverrideDraft == nil)
        let bytes = try image(red: 0.9)

        try await composition.runtime.saveImageOverride(
            kind: request.kind,
            key: request.key,
            title: request.title,
            subtitle: request.subtitle,
            data: bytes,
        )

        #expect(try await composition.store.imageOverride(kind: .artist, key: request.key) != nil,
                "the captured entity receives the file without a draft")
        #expect(composition.state.imageOverrideDraft == nil)
    }

    /// The user can start Replace on another row while the first file is
    /// read. The save still targets the chosen entity, and the other entity's
    /// draft is left for its own save.
    @Test func anExplicitSaveTargetsItsOwnEntityAndLeavesAnotherDraft() async throws {
        let composition = try await entityComposition { _ in entityLastFMArtistInfo() }
        let chosen = try artistRequest("Blondie")
        let other = try artistRequest("Talking Heads")
        composition.runtime.beginImageOverride(chosen)
        composition.runtime.beginImageOverride(other)
        let bytes = try image(red: 0.9)

        try await composition.runtime.saveImageOverride(
            kind: chosen.kind,
            key: chosen.key,
            title: chosen.title,
            subtitle: chosen.subtitle,
            data: bytes,
        )

        #expect(try await composition.store.imageOverride(kind: .artist, key: chosen.key) != nil)
        #expect(try await composition.store.imageOverride(kind: .artist, key: other.key) == nil,
                "the chosen file is not saved over the other entity")
        #expect(composition.state.imageOverrideDraft?.key == other.key,
                "another entity's draft is left alone")
    }

    @Test func anExplicitSaveSurvivesTheDraftChangingDuringTheStoreWrite() async throws {
        let database = try TemporaryDatabase()
        let base = try SQLiteListenStore(url: database.url)
        let saveGate = ChartHoldGate()
        let store = HoldingOverridesStore(
            base,
            gate: ChartHoldGate(),
            saveGate: saveGate,
        )
        let composition = try await entityComposition(
            database: database,
            existingStore: base,
            runtimeStore: store,
        ) { _ in entityLastFMArtistInfo() }
        let chosen = try artistRequest("Blondie")
        let other = try artistRequest("Talking Heads")
        let bytes = try image()

        await saveGate.startHolding()
        let save = Task {
            try await composition.runtime.saveImageOverride(
                kind: chosen.kind,
                key: chosen.key,
                title: chosen.title,
                subtitle: chosen.subtitle,
                data: bytes,
            )
        }
        #expect(await saveGate.waitUntilEntered(1), "the save is in flight")

        // The Images page moves on while the chosen bytes are being stored.
        composition.runtime.beginImageOverride(other)
        await saveGate.release()
        try await save.value

        #expect(try await base.imageOverride(kind: .artist, key: chosen.key) != nil)
        #expect(try await base.imageOverride(kind: .artist, key: other.key) == nil)
        #expect(composition.state.imageOverrideDraft?.key == other.key)
    }

    @Test func anOversizedSelectionIsRefusedBeforeItEntersTheStore() async throws {
        let composition = try await entityComposition { _ in entityLastFMArtistInfo() }
        try await linkLastFM(composition)
        let request = try artistRequest()
        let oversized = Data(count: ImageOverridePolicy.maximumSourceBytes + 1)
        do {
            try await composition.runtime.saveImageOverride(
                kind: .artist,
                key: request.key,
                title: request.title,
                subtitle: request.subtitle,
                data: oversized,
            )
            Issue.record("an oversized image was accepted")
        } catch let error as ImageOverrideError {
            #expect(error == .tooLarge)
        }
        #expect(try await composition.store.imageOverrideCount() == 0)
    }

    // MARK: - Image precedence

    @Test func albumImagesUseOverrideThenCapturedThenServiceThenNeutral() async throws {
        let composition = try await entityComposition { request in
            if formParameters(request)["method"] == "album.getInfo" {
                return entityLastFMAlbumInfo(image: "https://images.example/album.jpg")
            }
            if request.url.path.hasSuffix("album.jpg") {
                return entityImageResponse(try? testImageData(red: 0.35, green: 0.55, blue: 0.3))
            }
            return entityLastFMError(3, message: "Invalid Method")
        }
        let capturedBytes = try image(red: 0.9)
        let captured = try #require(ArtworkNormalizer.normalize(capturedBytes))
        let listen = try #require(
            try await composition.store.insert(
                entityListen(
                    title: "Heart of Glass",
                    artist: "Blondie",
                    album: "Parallel Lines",
                    start: historyBase,
                ),
            ),
        )
        try await composition.store.attachArtwork(captured, toTrack: listen.raw.identity)
        _ = try await composition.store.insert(
            entityListen(
                title: "Dreaming",
                artist: "Blondie",
                album: "Eat to the Beat",
                start: historyBase.addingTimeInterval(60),
            ),
        )
        _ = try await linkLastFM(composition)

        try await composition.runtime.openEntityDetail(albumRequest())
        #expect(await waitForEntityImage(composition.state, source: .captured))
        #expect(await composition.transport.requests(pathEndingWith: "album.jpg").isEmpty,
                "the captured cover is above the service image")

        let album = try albumRequest()
        let albumOverrideImage = try image(blue: 0.8)
        try await composition.runtime.saveImageOverride(
            kind: .album,
            key: album.key,
            title: album.title,
            subtitle: album.subtitle,
            data: albumOverrideImage,
        )
        #expect(composition.state.entityDetail?.imageSource == .override)
        #expect(await composition.transport.requests(pathEndingWith: "album.jpg").isEmpty)

        try await composition.runtime.removeImageOverride(kind: .album, key: album.key)
        #expect(composition.state.entityDetail?.imageSource == .captured)

        try await composition.runtime.openEntityDetail(albumRequest("Eat to the Beat", artist: "Blondie"))
        #expect(await waitForEntityImage(composition.state, source: .service))
        #expect(await composition.transport.requests(pathEndingWith: "album.jpg").count == 1)
    }

    @Test func anUnavailableAlbumImageEndsInTheNeutralSleeve() async throws {
        let composition = try await entityComposition { request in
            if formParameters(request)["method"] == "album.getInfo" {
                return entityLastFMAlbumInfo(image: nil)
            }
            return entityLastFMError(3, message: "Invalid Method")
        }
        _ = try await composition.store.insert(
            entityListen(
                title: "Dreaming",
                artist: "Blondie",
                album: "Eat to the Beat",
                start: historyBase,
            ),
        )
        _ = try await linkLastFM(composition)
        try await composition.runtime.openEntityDetail(albumRequest("Eat to the Beat", artist: "Blondie"))
        #expect(await waitForEntityService(composition.state) {
            if case .facts = $0 {
                true
            } else {
                false
            }
        })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(composition.state.entityDetail?.imageSource == .neutral)
        #expect(await composition.transport.requests(pathEndingWith: "album.jpg").isEmpty)
    }

    @Test func aTrackUsesItsCapturedCoverAndNeverSearchesForAnArtistImage() async throws {
        let composition = try await entityComposition { request in
            if formParameters(request)["method"] == "track.getInfo" {
                return entityLastFMTrackInfo()
            }
            if request.url.host == "itunes.apple.com" {
                Issue.record("a track page searched for an artist image")
            }
            return entityLastFMError(3, message: "Invalid Method")
        }
        let bytes = try image(red: 0.7)
        let stored = try #require(ArtworkNormalizer.normalize(bytes))
        let listen = try #require(
            try await composition.store.insert(
                entityListen(
                    title: "Heart of Glass",
                    artist: "Blondie",
                    album: "Parallel Lines",
                    start: historyBase,
                ),
            ),
        )
        try await composition.store.attachArtwork(stored, toTrack: listen.raw.identity)
        _ = try await linkLastFM(composition)

        try await composition.runtime.openEntityDetail(trackRequest())
        #expect(await waitForEntityImage(composition.state, source: .captured))
        #expect(await composition.transport.itunesRequests().isEmpty)
    }

    // MARK: - Approximate artist images

    private func artistSearchHandler(
        // swiftlint:disable:next large_tuple
        _ rows: [(artistID: String, artistName: String, artwork: String?)],
    ) -> @Sendable (HTTPRequest) throws -> HTTPResponse {
        { request in
            if request.url.host == "itunes.apple.com" {
                return entityITunesResponse(rows)
            }
            if request.url.path.hasSuffix("artist.jpg") {
                return entityImageResponse(try? testImageData(red: 0.3, green: 0.8, blue: 0.4))
            }
            if formParameters(request)["method"] == "artist.getInfo" {
                return entityLastFMArtistInfo()
            }
            return entityLastFMError(3, message: "Invalid Method")
        }
    }

    @Test func approximateArtistImagesUseAnExactMatchAndCarryThePrivacyContract() async throws {
        let composition = try await entityComposition(
            handler: artistSearchHandler([
                ("1012882", "Blondie", "https://images.example/artist.jpg"),
            ]),
        )
        try await linkLastFM(composition)
        try await composition.runtime.openEntityDetail(artistRequest())
        #expect(await waitForEntityImage(composition.state, source: .approximate))
        let detail = try #require(composition.state.entityDetail)
        #expect(detail.isApproximateImage)
        #expect(composition.state.imageOverrides.isEmpty)

        let requests = await composition.transport.itunesRequests()
        let request = try #require(requests.first)
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        #expect(values["entity"] == "album")
        #expect(values["attribute"] == "artistTerm")
        #expect(values["limit"] == "10")
        #expect(values["term"] == "Blondie")
        #expect(request.headers["Authorization"] == nil)
        #expect(!request.url.absoluteString.contains("api_key"))
        #expect(try await composition.store.artistImageCacheCount() == 1)
    }

    @Test func twoArtistIDsWithTheSameNameUseTheNeutralSleeve() async throws {
        let composition = try await entityComposition(
            handler: artistSearchHandler([
                ("1", "Blondie", "https://images.example/artist.jpg"),
                ("2", "Blondie", "https://images.example/artist.jpg"),
            ]),
        )
        try await linkLastFM(composition)
        try await composition.runtime.openEntityDetail(artistRequest())
        #expect(await waitForTransportRequests(composition.transport, atLeast: 1))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(composition.state.entityDetail?.imageSource == .neutral)
        #expect(try await composition.store.artistImageCacheCount() == 1)
    }

    @Test func aCachedApproximateImageAvoidsRequestsForThirtyDays() async throws {
        let composition = try await entityComposition(
            handler: artistSearchHandler([
                ("1012882", "Blondie", "https://images.example/artist.jpg"),
            ]),
        )
        try await linkLastFM(composition)
        try await composition.runtime.openEntityDetail(artistRequest())
        #expect(await waitForEntityImage(composition.state, source: .approximate))
        let firstCount = await composition.transport.itunesRequests().count
        #expect(firstCount == 1)

        try await composition.runtime.openEntityDetail(artistRequest())
        #expect(await waitForEntityImage(composition.state, source: .approximate))
        #expect(await composition.transport.itunesRequests().count == 1)

        composition.clock.advance(to: composition.clock.now.addingTimeInterval(
            ArtistImageLookup.hitLifetime + 60,
        ))
        try await composition.runtime.openEntityDetail(artistRequest())
        #expect(await waitForTransportRequests(composition.transport, atLeast: 2))
        #expect(await composition.transport.itunesRequests().count == 2)
    }

    @Test func aDefiniteMissIsRetriedAfterADayButAFailureIsRetriedOnTheNextOpen() async throws {
        let ambiguous = try await entityComposition(
            handler: artistSearchHandler([
                ("1", "Blondie", "https://images.example/artist.jpg"),
                ("2", "Blondie", "https://images.example/artist.jpg"),
            ]),
        )
        try await linkLastFM(ambiguous)
        try await ambiguous.runtime.openEntityDetail(artistRequest())
        #expect(await waitForTransportRequests(ambiguous.transport, atLeast: 1))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(try await ambiguous.store.artistImageCacheCount() == 1)

        try await ambiguous.runtime.openEntityDetail(artistRequest())
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await ambiguous.transport.itunesRequests().count == 1)

        ambiguous.clock.advance(to: ambiguous.clock.now.addingTimeInterval(
            ArtistImageLookup.missLifetime + 60,
        ))
        try await ambiguous.runtime.openEntityDetail(artistRequest())
        #expect(await waitForTransportRequests(ambiguous.transport, atLeast: 2))

        let failing = try await entityComposition { request in
            if request.url.host == "itunes.apple.com" {
                throw URLError(.notConnectedToInternet)
            }
            return entityLastFMError(3, message: "Invalid Method")
        }
        try await linkLastFM(failing)
        try await failing.runtime.openEntityDetail(artistRequest())
        #expect(await waitForTransportRequests(failing.transport, atLeast: 1))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(try await failing.store.artistImageCacheCount() == 0)
        #expect(failing.state.entityDetail?.imageSource == .neutral)

        try await failing.runtime.openEntityDetail(artistRequest())
        #expect(await waitForTransportRequests(failing.transport, atLeast: 2))
    }

    @Test func theLookupSwitchOffSendsNothingAndStillShowsOverrides() async throws {
        let composition = try await entityComposition(
            handler: artistSearchHandler([
                ("1012882", "Blondie", "https://images.example/artist.jpg"),
            ]),
        )
        try await linkLastFM(composition)
        composition.runtime.setArtistImageLookupsEnabled(false)
        #expect(composition.state.artistImageLookupsEnabled == false)

        let override = try await saveArtistOverride(composition, data: image(red: 0.4))
        try await composition.runtime.openEntityDetail(artistRequest())
        try? await Task.sleep(for: .milliseconds(100))
        #expect(composition.state.entityDetail?.imageSource == .override)
        #expect(await composition.transport.itunesRequests().isEmpty)

        try await composition.runtime.removeImageOverride(kind: .artist, key: override.key)
        composition.runtime.setArtistImageLookupsEnabled(true)
        #expect(await waitForEntityImage(composition.state, source: .approximate))
        #expect(await !(composition.transport.itunesRequests()).isEmpty)
    }

    @Test func anOverrideMeansNoAppleRequest() async throws {
        let composition = try await entityComposition(
            handler: artistSearchHandler([
                ("1012882", "Blondie", "https://images.example/artist.jpg"),
            ]),
        )
        try await linkLastFM(composition)
        _ = try await saveArtistOverride(composition, data: image())
        try await composition.runtime.openEntityDetail(artistRequest())
        try? await Task.sleep(for: .milliseconds(100))
        #expect(composition.state.entityDetail?.imageSource == .override)
        #expect(await composition.transport.itunesRequests().isEmpty)
    }

    @Test func switchingLookupsOffHidesACachedApproximateImageWithoutARequest() async throws {
        let composition = try await entityComposition(
            handler: artistSearchHandler([
                ("1012882", "Blondie", "https://images.example/artist.jpg"),
            ]),
        )
        try await linkLastFM(composition)
        try await composition.runtime.openEntityDetail(artistRequest())
        #expect(await waitForEntityImage(composition.state, source: .approximate))
        let requestCount = await composition.transport.itunesRequests().count
        #expect(requestCount == 1)

        composition.runtime.setArtistImageLookupsEnabled(false)
        #expect(composition.state.entityDetail?.imageSource == .neutral)
        try await composition.runtime.openEntityDetail(artistRequest())
        try? await Task.sleep(for: .milliseconds(100))
        #expect(composition.state.entityDetail?.imageSource == .neutral)
        #expect(await composition.transport.itunesRequests().count == requestCount)

        composition.runtime.setArtistImageLookupsEnabled(true)
        #expect(await waitForEntityImage(composition.state, source: .approximate))
        #expect(await composition.transport.itunesRequests().count == requestCount,
                "a cached hit answers without another request")
    }

    @Test func anExpiredApproximateImageIsRemovedWithItsBlob() async throws {
        let counter = EntityCallCounter()
        let composition = try await entityComposition { request in
            if request.url.host == "itunes.apple.com" {
                return entityITunesResponse([
                    ("1012882", "Blondie", "https://images.example/artist.jpg"),
                ])
            }
            if request.url.path.hasSuffix("artist.jpg") {
                let index = counter.take()
                return entityImageResponse(
                    try? testImageData(
                        red: 0.15 + Double(index) * 0.2,
                        green: 0.3,
                        blue: 0.5,
                    ),
                )
            }
            return entityLastFMError(3, message: "Invalid Method")
        }
        try await linkLastFM(composition)
        let key = try #require(LocalArtistIdentity.key(name: "Blondie"))
        try await composition.runtime.openEntityDetail(artistRequest())
        #expect(await waitForEntityImage(composition.state, source: .approximate))
        let first = try #require(try await composition.store.artistImageCache(forArtist: key))
        let firstHash = try #require(first.artworkHash)
        #expect(try await composition.store.artwork(for: firstHash) != nil)

        composition.clock.advance(to: composition.clock.now.addingTimeInterval(
            ArtistImageLookup.hitLifetime + 60,
        ))
        try await composition.runtime.openEntityDetail(artistRequest())
        #expect(await waitForTransportRequests(composition.transport, atLeast: 4))
        try? await Task.sleep(for: .milliseconds(100))
        let second = try #require(try await composition.store.artistImageCache(forArtist: key))
        let secondHash = try #require(second.artworkHash)
        #expect(firstHash != secondHash)
        #expect(try await composition.store.artwork(for: firstHash) == nil,
                "an expired approximate image leaves no orphaned bytes")
        #expect(try await composition.store.artwork(for: secondHash) != nil)
    }

    @Test func oversizeOrCorruptRemoteImagesEndInTheNeutralSleeve() async throws {
        let oversized = try await entityComposition { request in
            if request.url.host == "itunes.apple.com" {
                return entityITunesResponse([
                    ("1", "Blondie", "https://images.example/artist.jpg"),
                ])
            }
            if request.url.path.hasSuffix("artist.jpg") {
                return entityImageResponse(Data(count: ImageOverridePolicy.maximumRemoteBytes + 1))
            }
            return entityLastFMError(3, message: "Invalid Method")
        }
        try await linkLastFM(oversized)
        try await oversized.runtime.openEntityDetail(artistRequest())
        #expect(await waitForTransportRequests(oversized.transport, atLeast: 2))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(oversized.state.entityDetail?.imageSource == .neutral)
        #expect(try await oversized.store.artistImageCacheCount() == 0)

        let corrupt = try await entityComposition { request in
            if request.url.host == "itunes.apple.com" {
                return entityITunesResponse([
                    ("1", "Blondie", "https://images.example/artist.jpg"),
                ])
            }
            if request.url.path.hasSuffix("artist.jpg") {
                return entityImageResponse(Data("not an image".utf8))
            }
            return entityLastFMError(3, message: "Invalid Method")
        }
        try await linkLastFM(corrupt)
        try await corrupt.runtime.openEntityDetail(artistRequest())
        #expect(await waitForTransportRequests(corrupt.transport, atLeast: 2))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(corrupt.state.entityDetail?.imageSource == .neutral)
        #expect(try await corrupt.store.artistImageCacheCount() == 0)
    }

    @Test func aServiceAlbumImageIsOnlyFetchedWhenPrecedenceReachesIt() async throws {
        let composition = try await entityComposition { request in
            if formParameters(request)["method"] == "album.getInfo" {
                return entityLastFMAlbumInfo(image: "https://images.example/album.jpg")
            }
            if request.url.path.hasSuffix("album.jpg") {
                return entityImageResponse(Data(count: ImageOverridePolicy.maximumRemoteBytes + 1))
            }
            return entityLastFMError(3, message: "Invalid Method")
        }
        _ = try await composition.store.insert(
            entityListen(
                title: "Dreaming",
                artist: "Blondie",
                album: "Eat to the Beat",
                start: historyBase,
            ),
        )
        _ = try await linkLastFM(composition)
        try await composition.runtime.openEntityDetail(albumRequest("Eat to the Beat", artist: "Blondie"))
        #expect(await waitForEntityService(composition.state) {
            if case .facts = $0 {
                true
            } else {
                false
            }
        })
        #expect(await waitForTransportRequests(composition.transport, atLeast: 2))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(composition.state.entityDetail?.imageSource == .neutral)
    }
}

// MARK: - Small test conveniences
