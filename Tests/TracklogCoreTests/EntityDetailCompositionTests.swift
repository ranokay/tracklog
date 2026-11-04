import Foundation
import Testing
@testable import TracklogCore

// swiftlint:disable file_length

// MARK: - Local content and navigation

@Suite("Entity details")
@MainActor
// swiftlint:disable:next type_body_length
struct EntityDetailCompositionTests {
    private func artistRequest(_ name: String = "Blondie") throws -> EntityRequest {
        try #require(EntityRequest.artist(name: name))
    }

    private func albumRequest(
        _ album: String = "Parallel Lines",
        artist: String = "Blondie",
    ) throws -> EntityRequest {
        try #require(EntityRequest.album(album: album, artist: artist))
    }

    private func trackRequest(
        _ title: String = "Heart of Glass",
        artist: String = "Blondie",
    ) throws -> EntityRequest {
        try #require(EntityRequest.track(title: title, artist: artist))
    }

    private func linkLastFM(
        _ composition: EntityTestComposition,
        identity: String = "listener",
    ) async throws -> Connection {
        try await composition.runtime.linkVerified(
            kind: .lastFM,
            credential: "session",
            identity: ServiceIdentity(name: identity),
        )
    }

    private func linkListenBrainz(
        _ composition: EntityTestComposition,
        identity: String = "brainz",
    ) async throws -> Connection {
        try await composition.runtime.linkVerified(
            kind: .listenBrainz,
            credential: "token",
            identity: ServiceIdentity(name: identity),
        )
    }

    @Test func localSectionIsGlobalAndIgnoresTheCurrentConnection() async throws {
        let composition = try await entityComposition(listenBrainzAdapter: true) { request in
            if formParameters(request)["method"] == "artist.getInfo" {
                return entityLastFMArtistInfo()
            }
            return entityLastFMError(3, message: "Invalid Method")
        }
        try await seedEntityHistory(composition.store)
        _ = try await linkLastFM(composition)

        try await composition.runtime.openEntityDetail(artistRequest())
        var detail = try #require(composition.state.entityDetail)
        #expect(detail.local.count == 3)
        #expect(detail.local.firstListenedAt == historyBase)
        #expect(detail.local.lastListenedAt == historyBase.addingTimeInterval(120))
        #expect(detail.local.topTracks.first?.title == "Heart of Glass")
        #expect(detail.local.topTracks.first?.count == 3)

        #expect(await waitForEntityService(composition.state) {
            if case .facts = $0 {
                true
            } else {
                false
            }
        })

        _ = try await linkListenBrainz(composition)
        #expect(await waitForEntityService(composition.state) {
            if case .unavailable = $0 {
                true
            } else {
                false
            }
        })
        detail = try #require(composition.state.entityDetail)
        #expect(detail.local.count == 3, "the local section never reads the connection")
        #expect(detail.local.lastListenedAt == historyBase.addingTimeInterval(120))
    }

    @Test func historyAndChartRowsResolveTheSameLocalKeys() async throws {
        let composition = try await entityComposition { _ in
            entityLastFMAlbumInfo()
        }
        try await seedEntityHistory(composition.store)
        _ = try await linkLastFM(composition)
        await composition.runtime.reloadHistory()

        let historyListen = try #require(
            composition.state.listens.first { $0.processed.title == "Heart of Glass" },
        )
        let historyRequest = try #require(EntityRequest.album(from: historyListen))
        let chartItem = ChartItem(
            rank: 1,
            title: "Parallel Lines",
            subtitle: "Blondie",
            count: 30,
            identityKey: "service-key",
        )
        let chartRequest = try #require(EntityRequest.chartItem(chartItem, type: .albums))
        #expect(historyRequest.key == chartRequest.key)
        #expect(historyRequest.key == LocalAlbumIdentity.key(
            album: "Parallel Lines",
            artist: "Blondie",
        ))

        await composition.runtime.openEntityDetail(chartRequest)
        let detail = try #require(composition.state.entityDetail)
        #expect(detail.local.count == 3)
        #expect(detail.local.topTracks.first?.title == "Heart of Glass")
    }

    @Test func lastFMServiceFactsCarryTheAccountPlayCountAndConnectionName() async throws {
        let composition = try await entityComposition { request in
            if formParameters(request)["method"] == "artist.getInfo" {
                return entityLastFMArtistInfo(listeners: 5, plays: 10, userPlays: 3)
            }
            return entityLastFMError(3, message: "Invalid Method")
        }
        try await seedEntityHistory(composition.store)
        _ = try await linkLastFM(composition, identity: "listener")

        try await composition.runtime.openEntityDetail(artistRequest())
        #expect(await waitForEntityService(composition.state) {
            if case .facts = $0 {
                true
            } else {
                false
            }
        })
        guard case let .facts(facts)? = composition.state.entityDetail?.service else {
            Issue.record("expected service facts")
            return
        }
        #expect(facts.serviceName == "Last.fm")
        #expect(facts.accountName == "listener")
        #expect(facts.facts.contains(EntityFact(label: "Your plays", value: "3")))
        #expect(facts.link?.absoluteString == "https://www.last.fm/music/Blondie")

        let requests = await composition.transport.allRequests()
        let parameters = try #require(requests.first.map(formParameters))
        #expect(parameters["method"] == "artist.getInfo")
        #expect(parameters["artist"] == "Blondie")
        #expect(parameters["username"] == "listener")
        #expect(parameters["api_key"] == "api-key")
        #expect(parameters["sk"] == nil, "a detail read needs no user session key")
    }

    @Test func historyLovedAndPaletteRowsUseTheSameLocalKeys() throws {
        let catalogueArtist = CatalogueRow(
            group: .artists,
            title: "Blondie",
            subtitle: "",
            playbackQuery: "",
            pageURL: nil,
        )
        #expect(EntityRequest.catalogueRow(catalogueArtist)?.key
            == LocalArtistIdentity.key(name: "Blondie"))

        let catalogueAlbum = CatalogueRow(
            group: .albums,
            title: "Parallel Lines",
            subtitle: "Blondie",
            playbackQuery: "",
            pageURL: nil,
        )
        #expect(EntityRequest.catalogueRow(catalogueAlbum)?.key
            == LocalAlbumIdentity.key(album: "Parallel Lines", artist: "Blondie"))

        let loved = LovedRow(
            connectionID: 1,
            id: "listenbrainz:mbid:abc",
            title: "Heart of Glass",
            artist: "Blondie",
            album: "Parallel Lines",
            reference: .mbid("abc"),
        )
        let lovedRequest = try #require(EntityRequest.lovedRow(loved))
        #expect(lovedRequest.key == LocalTrackIdentity.key(
            title: "Heart of Glass",
            artist: "Blondie",
        ))
        #expect(lovedRequest.providerID == "abc",
                "the Loved row's MBID reaches the ListenBrainz link")
    }

    @Test func nonLastFMConnectionsExplainAndOnlyListenBrainzLinksWithAnMBID() async throws {
        let composition = try await entityComposition(
            extraAdapters: [LibreFMAdapter(transport: EntityTransport { _ in
                entityLastFMError(3, message: "Invalid Method")
            })],
            listenBrainzAdapter: true,
        ) { _ in
            entityLastFMArtistInfo()
        }
        try await seedEntityHistory(composition.store)

        let mbid = "9c8f7a1e-2f4d-4a1e-8d4c-2b7c6e5a1f30"
        let album = EntityRequest(
            kind: .album,
            key: LocalAlbumIdentity.key(album: "Parallel Lines", artist: "Blondie") ?? "",
            title: "Parallel Lines",
            subtitle: "Blondie",
            providerID: mbid,
        )
        _ = try await linkListenBrainz(composition)
        await composition.runtime.openEntityDetail(album)
        #expect(await waitForEntityService(composition.state) {
            if case .unavailable = $0 {
                true
            } else {
                false
            }
        })
        #expect(EntityServiceCopy.listenBrainzLink(kind: .album, providerID: mbid)?.absoluteString
            == "https://listenbrainz.org/release/\(mbid)")
        #expect(EntityServiceCopy.listenBrainzLink(kind: .artist, providerID: nil) == nil)
        #expect(await composition.transport.methods().filter { $0.contains(".getInfo") }.isEmpty)

        _ = try await composition.runtime.linkVerified(
            kind: .libreFM,
            credential: "libre-token",
            identity: ServiceIdentity(name: "libre-listener"),
        )
        try await composition.runtime.openEntityDetail(artistRequest())
        #expect(await waitForEntityService(composition.state) {
            if case let .unavailable(message) = $0 {
                message.contains("Libre.fm")
            } else {
                false
            }
        })
        #expect(await composition.transport.methods().filter { $0.contains(".getInfo") }.isEmpty)
    }

    @Test func connectionChangeClearsTheServiceSectionAndIgnoresTheLateReply() async throws {
        let composition = try await entityComposition(
            listenBrainzAdapter: true,
            hold: { formParameters($0)["method"] == "artist.getInfo" },
            timeout: 5,
            handler: { request in
                if formParameters(request)["method"] == "artist.getInfo" {
                    return entityLastFMArtistInfo(userPlays: 42)
                }
                return entityLastFMError(3, message: "Invalid Method")
            },
        )
        try await seedEntityHistory(composition.store)
        _ = try await linkLastFM(composition)
        try await composition.runtime.openEntityDetail(artistRequest())
        #expect(await composition.transport.waitUntilEntered(1))

        _ = try await linkListenBrainz(composition)
        #expect(await waitForEntityService(composition.state) {
            if case .unavailable = $0 {
                true
            } else {
                false
            }
        })

        await composition.transport.release()
        try? await Task.sleep(for: .milliseconds(100))
        guard case .unavailable? = composition.state.entityDetail?.service else {
            Issue.record("a late Last.fm reply replaced the new connection's reason")
            return
        }
        #expect(composition.state.entityDetail?.local.count == 3)
    }

    @Test func reopeningADetailReadsTheServiceAgain() async throws {
        let composition = try await entityComposition { request in
            if formParameters(request)["method"] == "artist.getInfo" {
                return entityLastFMArtistInfo()
            }
            return entityLastFMError(3, message: "Invalid Method")
        }
        try await seedEntityHistory(composition.store)
        _ = try await linkLastFM(composition)

        for _ in 0 ..< 2 {
            try await composition.runtime.openEntityDetail(artistRequest())
            #expect(await waitForEntityService(composition.state) {
                if case .facts = $0 {
                    true
                } else {
                    false
                }
            })
        }
        let count = await composition.transport.methods()
            .filter { $0 == "artist.getInfo" }
            .count
        #expect(count == 2, "detail reads have no persistent cache")
    }

    @Test func thePageStackPushesTracksAndBackReloadsTheRevealedPage() async throws {
        let composition = try await entityComposition { request in
            if formParameters(request)["method"] == "artist.getInfo" {
                return entityLastFMArtistInfo()
            }
            return entityLastFMError(3, message: "Invalid Method")
        }
        try await seedEntityHistory(composition.store)
        _ = try await linkLastFM(composition)

        try await composition.runtime.openEntityDetail(artistRequest())
        #expect(await waitForEntityService(composition.state) {
            if case .facts = $0 {
                true
            } else {
                false
            }
        })
        let top = try #require(composition.state.entityDetail?.local.topTracks.first)
        let trackRequest = try #require(EntityRequest.chartItem(top, type: .tracks))
        await composition.runtime.pushEntityDetail(trackRequest)
        #expect(composition.state.entityDetail?.request.kind == .track)
        #expect(composition.state.entityDetail?.track?.totalCount == 3)
        #expect(composition.runtime.entityDetail?.stackDepth == 2)

        await composition.runtime.backEntityDetail()
        #expect(composition.state.entityDetail?.request.kind == .artist)
        #expect(composition.state.entityDetail?.local.count == 3)
        #expect(await waitForEntityService(composition.state) {
            if case .facts = $0 {
                true
            } else {
                false
            }
        })
        let count = await composition.transport.methods()
            .filter { $0 == "artist.getInfo" }
            .count
        #expect(count == 2, "Back reloads the revealed page")

        await composition.runtime.backEntityDetail()
        #expect(composition.state.entityDetail == nil)
        #expect(composition.runtime.entityDetail?.stackDepth == 0)
    }

    @Test func aLateReplyFromThePageJustLeftCannotOverwriteTheNewPage() async throws {
        let composition = try await entityComposition(
            hold: { formParameters($0)["method"] == "artist.getInfo" },
            timeout: 5,
            handler: { request in
                if formParameters(request)["method"] == "artist.getInfo" {
                    return entityLastFMArtistInfo(userPlays: 77)
                }
                return entityLastFMError(3, message: "Invalid Method")
            },
        )
        try await seedEntityHistory(composition.store)
        _ = try await linkLastFM(composition)

        try await composition.runtime.openEntityDetail(artistRequest())
        #expect(await composition.transport.waitUntilEntered(1))
        let top = try #require(composition.state.entityDetail?.local.topTracks.first)
        let trackRequest = try #require(EntityRequest.chartItem(top, type: .tracks))
        await composition.runtime.pushEntityDetail(trackRequest)
        await composition.transport.release()
        try? await Task.sleep(for: .milliseconds(100))

        #expect(composition.state.entityDetail?.request.kind == .track)
        #expect(composition.state.entityDetail?.request.title == "Heart of Glass")
        if case .facts? = composition.state.entityDetail?.service {
            Issue.record("the old artist's facts landed on the track page")
        }
    }

    @Test func thePageStackStaysBounded() async throws {
        let composition = try await entityComposition { request in
            if formParameters(request)["method"] == "artist.getInfo" {
                return entityLastFMArtistInfo()
            }
            return entityLastFMError(3, message: "Invalid Method")
        }
        _ = try await linkLastFM(composition)
        try await composition.runtime.openEntityDetail(artistRequest())
        for index in 0 ..< 25 {
            let request = try #require(
                EntityRequest.track(title: "Song \(index)", artist: "Blondie"),
            )
            await composition.runtime.pushEntityDetail(request)
        }
        #expect(composition.runtime.entityDetail?.stackDepth == EntityDetailReadModel.maximumStackDepth)

        for _ in 0 ..< (EntityDetailReadModel.maximumStackDepth - 1) {
            await composition.runtime.backEntityDetail()
        }
        #expect(composition.state.entityDetail != nil)
        #expect(composition.runtime.entityDetail?.stackDepth == 1)
        await composition.runtime.backEntityDetail()
        #expect(composition.state.entityDetail == nil)
    }

    @Test func aStartedOverrideKeepsItsDraftAfterTheDetailCloses() async throws {
        let composition = try await entityComposition { _ in
            entityLastFMArtistInfo()
        }
        try await linkLastFM(composition)
        try await composition.runtime.openEntityDetail(artistRequest())
        let request = try artistRequest()
        composition.runtime.beginImageOverride(request)
        #expect(composition.state.imageOverrideDraft != nil)

        composition.runtime.closeEntityDetail()
        #expect(composition.state.imageOverrideDraft?.key == request.key,
                "Change image… dismisses the takeover, so the draft must survive")

        let bytes = try #require(testImageData(red: 0.2, green: 0.7, blue: 0.3))
        try await composition.runtime.saveSelectedImageOverride(bytes)
        #expect(composition.state.imageOverrides.count == 1)
        #expect(try await composition.store.imageOverrideCount() == 1)
    }

    @Test func aDeleteOnTheTrackPageKeepsEveryLoadedPage() async throws {
        let composition = try await entityComposition { request in
            if formParameters(request)["method"] == "track.getInfo" {
                return entityLastFMTrackInfo()
            }
            return entityLastFMError(3, message: "Invalid Method")
        }
        for index in 0 ..< 120 {
            _ = try await composition.store.insert(
                entityListen(
                    title: "Heart of Glass",
                    artist: "Blondie",
                    album: "Parallel Lines",
                    start: historyBase.addingTimeInterval(Double(index) * 60),
                ),
            )
        }
        try await linkLastFM(composition)
        try await composition.runtime.openEntityDetail(trackRequest())
        #expect(composition.state.entityDetail?.track?.listens.count == 50)
        await composition.runtime.loadMoreEntityListens()
        await composition.runtime.loadMoreEntityListens()
        let track = try #require(composition.state.entityDetail?.track)
        #expect(track.listens.count == 120)
        let laterID = try #require(track.listens[90].id)
        let victim = try #require(track.listens.first)

        try await composition.runtime.deleteListen(victim)

        let after = try #require(composition.state.entityDetail?.track)
        #expect(after.listens.count == 119, "rows loaded beyond the first page survive a delete")
        #expect(after.listens.contains { $0.id == laterID })
        #expect(after.totalCount == 119)
    }

    @Test func aFailedReloadKeepsTheRowsAndLeavesTheServiceAlone() async throws {
        let database = try TemporaryDatabase()
        let base = try SQLiteListenStore(url: database.url)
        let failing = FailingEntityDetailStore(base, failures: 0)
        let composition = try await entityComposition(
            database: database,
            existingStore: base,
            runtimeStore: failing,
        ) { request in
            if formParameters(request)["method"] == "track.getInfo" {
                return entityLastFMTrackInfo()
            }
            return entityLastFMError(3, message: "Invalid Method")
        }
        for index in 0 ..< 120 {
            _ = try await base.insert(
                entityListen(
                    title: "Heart of Glass",
                    artist: "Blondie",
                    album: "Parallel Lines",
                    start: historyBase.addingTimeInterval(Double(index) * 60),
                ),
            )
        }
        try await linkLastFM(composition)
        try await composition.runtime.openEntityDetail(trackRequest())
        await composition.runtime.loadMoreEntityListens()
        await composition.runtime.loadMoreEntityListens()
        #expect(await waitForEntityService(composition.state) {
            if case .facts = $0 {
                true
            } else {
                false
            }
        })
        let service = try #require(composition.state.entityDetail?.service)
        let rows = try #require(composition.state.entityDetail?.track?.listens)
        #expect(rows.count == 120)

        await failing.failNextDetailRead()
        await composition.runtime.reloadEntityDetail()

        let after = try #require(composition.state.entityDetail?.track)
        #expect(after.listens.count == 120, "a failed re-read keeps the loaded rows")
        #expect(after.failure != nil, "the failure bar appears beside the rows")
        #expect(composition.state.entityDetail?.service == service,
                "a local reload leaves the service section alone")
    }

    @Test func listenBrainzChartRowsCarryTheirMBIDsForEveryEntity() async throws {
        let transport = EntityTransport { request in
            let path = request.url.path
            let payload = if path.contains("/artists") {
                """
                {"payload":{"artists":[{"artist_name":"Blondie",
                "artist_mbid":"artist-mbid","listen_count":12}]}}
                """
            } else if path.contains("/releases") {
                """
                {"payload":{"releases":[{"release_name":"Parallel Lines",
                "release_mbid":"release-mbid","artist_name":"Blondie","listen_count":9}]}}
                """
            } else {
                """
                {"payload":{"recordings":[{"track_name":"Heart of Glass",
                "recording_mbid":"recording-mbid","artist_name":"Blondie","listen_count":7}]}}
                """
            }
            return HTTPResponse(statusCode: 200, body: Data(payload.utf8))
        }
        let adapter = ListenBrainzAdapter(transport: transport)
        let connection = Connection(
            kind: .listenBrainz,
            endpoint: .listenBrainz,
            identity: "listener",
            createdAt: historyBase,
        )

        let artists = try await adapter.top(
            .artists, period: .week, connection: connection, credential: "token", limit: 10,
        )
        let artistRequest = try #require(EntityRequest.chartItem(artists.items[0], type: .artists))
        #expect(artistRequest.providerID == "artist-mbid")
        #expect(EntityServiceCopy.listenBrainzLink(
            kind: .artist,
            providerID: artistRequest.providerID,
        )?.absoluteString == "https://listenbrainz.org/artist/artist-mbid")

        let albums = try await adapter.top(
            .albums, period: .week, connection: connection, credential: "token", limit: 10,
        )
        let albumRequest = try #require(EntityRequest.chartItem(albums.items[0], type: .albums))
        #expect(albumRequest.providerID == "release-mbid")
        #expect(EntityServiceCopy.listenBrainzLink(
            kind: .album,
            providerID: albumRequest.providerID,
        )?.absoluteString == "https://listenbrainz.org/release/release-mbid")

        let tracks = try await adapter.top(
            .tracks, period: .week, connection: connection, credential: "token", limit: 10,
        )
        let trackRequest = try #require(EntityRequest.chartItem(tracks.items[0], type: .tracks))
        #expect(trackRequest.providerID == "recording-mbid")
        #expect(EntityServiceCopy.listenBrainzLink(
            kind: .track,
            providerID: trackRequest.providerID,
        )?.absoluteString == "https://listenbrainz.org/recording/recording-mbid")
    }

    /// The palette's Return presents History and opens the detail in either
    /// order. After a dismissal left the jumped rows loaded, the mount load
    /// must still replace them with the newest feed and leave the detail up;
    /// Back then reveals that feed, not the stale window.
    @Test func aPaletteOpenedDetailLeavesTheNewestFeedUnderneath() async throws {
        let composition = try await entityComposition { request in
            if formParameters(request)["method"] == "artist.getInfo" {
                return entityLastFMArtistInfo()
            }
            return entityLastFMError(3, message: "Invalid Method")
        }
        try await seedEntityHistory(composition.store)
        _ = try await linkLastFM(composition)
        await composition.runtime.reloadHistory()
        let newest = historyBase.addingTimeInterval(1_200)

        await composition.runtime.jumpHistory(to: historyBase.addingTimeInterval(60))
        #expect(composition.state.historyJumpNotice != nil)
        #expect(composition.state.listens.first?.startedAt == historyBase.addingTimeInterval(60))

        // The takeover closes; its hide resets the jump state but not the rows.
        composition.runtime.resetHistoryNavigation()
        #expect(composition.state.historyJumpNotice == nil)
        #expect(composition.state.listens.first?.startedAt == historyBase.addingTimeInterval(60),
                "the reset alone does not reload the jumped rows")

        // The detail opens before the mount load, the order that skipped the
        // feed while a detail was checked against nil.
        try await composition.runtime.openEntityDetail(artistRequest())
        await composition.runtime.reloadHistory()
        #expect(composition.state.entityDetail?.request.kind == .artist,
                "loading the feed must not close a palette-opened detail")
        #expect(composition.state.historyJumpNotice == nil)
        #expect(composition.state.listens.first?.startedAt == newest)

        await composition.runtime.backEntityDetail()
        #expect(composition.state.entityDetail == nil)
        #expect(composition.state.listens.first?.startedAt == newest,
                "Back reveals the newest feed, not the jumped rows")

        // The other order: the mount load finishes before the page opens.
        await composition.runtime.jumpHistory(to: historyBase.addingTimeInterval(60))
        composition.runtime.resetHistoryNavigation()
        await composition.runtime.reloadHistory()
        try await composition.runtime.openEntityDetail(artistRequest())
        #expect(composition.state.entityDetail?.request.kind == .artist,
                "a detail opened after the load stays up")
        #expect(composition.state.listens.first?.startedAt == newest)
    }

    // MARK: - Service failures

    private func openArtistAndWaitForService(
        _ composition: EntityTestComposition,
        match: @escaping @MainActor (EntityServiceSection) -> Bool,
    ) async throws -> EntityServiceSection {
        try await composition.runtime.openEntityDetail(artistRequest())
        #expect(await waitForEntityService(composition.state, until: match))
        return try #require(composition.state.entityDetail?.service)
    }

    @Test func missingAppCredentialsSendNoRequestAndOfferTheSettingsRemedy() async throws {
        let composition = try await entityComposition(appCredentials: .compiled) { request in
            if request.url.host == "itunes.apple.com" {
                return entityITunesResponse([])
            }
            Issue.record("a Last.fm detail request was sent without an app key")
            return entityLastFMError(10, message: "Invalid API key")
        }
        try await seedEntityHistory(composition.store)
        _ = try await linkLastFM(composition)

        let service = try await openArtistAndWaitForService(composition) {
            if case .failed = $0 {
                true
            } else {
                false
            }
        }
        guard case let .failed(failure) = service else {
            Issue.record("expected a failure")
            return
        }
        #expect(failure == .appCredentials(.missing))
        #expect(failure.needsSettings)
        #expect(await composition.transport.requests(toHost: "ws.audioscrobbler.com").isEmpty)
        #expect(composition.state.entityDetail?.local.count == 3)
    }

    @Test func rejectedAppCredentialsUseTheExistingClassification() async throws {
        let composition = try await entityComposition { _ in
            entityLastFMError(10, message: "Invalid API key")
        }
        try await seedEntityHistory(composition.store)
        _ = try await linkLastFM(composition)
        let service = try await openArtistAndWaitForService(composition) {
            if case .failed = $0 {
                true
            } else {
                false
            }
        }
        #expect(service == .failed(.appCredentials(.invalidKey)))
        #expect(composition.state.entityDetail?.local.count == 3)
    }

    @Test func needsSignInMapsFromARejectedSessionRead() async throws {
        let composition = try await entityComposition { _ in
            HTTPResponse(statusCode: 403, body: Data())
        }
        try await seedEntityHistory(composition.store)
        _ = try await linkLastFM(composition)
        let service = try await openArtistAndWaitForService(composition) {
            if case .failed = $0 {
                true
            } else {
                false
            }
        }
        #expect(service == .failed(.needsSignIn))
        #expect(composition.state.entityDetail?.local.count == 3)
    }

    @Test func offlineMapsFromATransportFailure() async throws {
        let composition = try await entityComposition { _ in
            throw URLError(.notConnectedToInternet)
        }
        try await seedEntityHistory(composition.store)
        _ = try await linkLastFM(composition)
        let service = try await openArtistAndWaitForService(composition) {
            if case .failed = $0 {
                true
            } else {
                false
            }
        }
        #expect(service == .failed(.offline))
        #expect(composition.state.entityDetail?.local.count == 3)
    }

    @Test func aFiveHundredIsReportedAsOfflineThroughTheExistingClassification() async throws {
        let composition = try await entityComposition { _ in
            HTTPResponse(statusCode: 503, body: Data())
        }
        try await seedEntityHistory(composition.store)
        _ = try await linkLastFM(composition)
        let service = try await openArtistAndWaitForService(composition) {
            if case .failed = $0 {
                true
            } else {
                false
            }
        }
        #expect(service == .failed(.offline))
    }

    @Test func rateLimitCarriesTheRetryAfter() async throws {
        let composition = try await entityComposition { _ in
            HTTPResponse(statusCode: 429, headers: ["Retry-After": "30"], body: Data())
        }
        try await seedEntityHistory(composition.store)
        _ = try await linkLastFM(composition)
        let service = try await openArtistAndWaitForService(composition) {
            if case .failed = $0 {
                true
            } else {
                false
            }
        }
        #expect(service == .failed(.rateLimited(retryAfter: 30)))
        #expect(composition.state.entityDetail?.local.count == 3)
    }

    @Test func timeoutKeepsLocalAndRetriesOnTheNextOpen() async throws {
        let composition = try await entityComposition(
            hold: { formParameters($0)["method"] == "artist.getInfo" },
            timeout: 0.05,
            handler: { request in
                if formParameters(request)["method"] == "artist.getInfo" {
                    return entityLastFMArtistInfo()
                }
                return entityLastFMError(3, message: "Invalid Method")
            },
        )
        try await seedEntityHistory(composition.store)
        _ = try await linkLastFM(composition)
        let service = try await openArtistAndWaitForService(composition) {
            if case .failed = $0 {
                true
            } else {
                false
            }
        }
        #expect(service == .failed(.timedOut))
        #expect(composition.state.entityDetail?.local.count == 3)
        await composition.transport.release()
    }

    @Test func entityNotFoundIsMissingNotAFailure() async throws {
        let composition = try await entityComposition { _ in
            entityLastFMError(6, message: "The artist you supplied could not be found.")
        }
        try await seedEntityHistory(composition.store)
        _ = try await linkLastFM(composition)
        let service = try await openArtistAndWaitForService(composition) {
            if case .missing = $0 {
                true
            } else {
                false
            }
        }
        guard case let .missing(message) = service else {
            Issue.record("expected the missing state")
            return
        }
        #expect(message.contains("no artist details"))
        #expect(composition.state.entityDetail?.local.count == 3)
    }

    @Test func aGenericServiceRejectionKeepsItsMessage() async throws {
        let composition = try await entityComposition { _ in
            entityLastFMError(7, message: "Invalid resource specified")
        }
        try await seedEntityHistory(composition.store)
        _ = try await linkLastFM(composition)
        let service = try await openArtistAndWaitForService(composition) {
            if case .failed = $0 {
                true
            } else {
                false
            }
        }
        #expect(service == .failed(.service("Invalid resource specified")))
        #expect(composition.state.entityDetail?.local.count == 3)
    }

    @Test func aFailedPageNeverShowsAnotherEntitysFacts() async throws {
        let counter = EntityCallCounter()
        let composition = try await entityComposition { request in
            if formParameters(request)["method"] == "artist.getInfo" {
                if counter.take() == 0 {
                    return entityLastFMArtistInfo(userPlays: 11)
                }
                return entityLastFMError(6, message: "The artist you supplied could not be found.")
            }
            return entityLastFMError(3, message: "Invalid Method")
        }
        try await seedEntityHistory(composition.store)
        _ = try await linkLastFM(composition)

        try await composition.runtime.openEntityDetail(artistRequest("Blondie"))
        #expect(await waitForEntityService(composition.state) {
            if case .facts = $0 {
                true
            } else {
                false
            }
        })
        try await composition.runtime.openEntityDetail(artistRequest("Fleetwood Mac"))
        #expect(await waitForEntityService(composition.state) {
            if case .missing = $0 {
                true
            } else {
                false
            }
        })
        if case .facts? = composition.state.entityDetail?.service {
            Issue.record("the previous artist's facts survived on the missing page")
        }
        #expect(composition.state.entityDetail?.request.title == "Fleetwood Mac")
    }
}

/// A Sendable counter for a scripted handler.
final class EntityCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func take() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value += 1
        return current
    }
}
