// swiftlint:disable file_length
import Foundation
import Testing
@testable import TracklogCore

@Suite("Catalogue search composition")
@MainActor
// swiftlint:disable:next type_body_length
struct CatalogueSearchCompositionTests: CaptureTestHelpers {
    @MainActor
    private struct Harness {
        let database: TemporaryDatabase
        let store: SQLiteListenStore
        let clock: FakeClock
        let runtime: CaptureRuntime
        let transport: CatalogueTransport

        var model: CatalogueSearchReadModel {
            get throws {
                try #require(runtime.catalogueSearch)
            }
        }

        var search: CatalogueSearchState {
            runtime.state.catalogueSearch
        }
    }

    private func makeHarness(
        transport: CatalogueTransport,
        appCredentials: LastFMAppCredentials = lastFMTestCredentials,
        current: ServiceKind? = .lastFM,
        enabled: Bool = false,
        timeout: TimeInterval = CatalogueSearchReadModel.defaultTimeout,
    ) async throws -> Harness {
        let database = try TemporaryDatabase()
        let store = try SQLiteListenStore(url: database.url)
        let clock = FakeClock(base)
        let credentials = MemoryCredentialStore()
        let adapters: [any ServiceAdapter] = [
            LastFMAdapter(
                transport: transport,
                appCredentials: StoredLastFMAppCredentials(
                    credentialStore: credentials,
                    compiled: appCredentials,
                ),
            ),
            StubAdapter(kind: .libreFM, identity: ServiceIdentity(name: "libre")),
            StubAdapter(kind: .listenBrainz, identity: ServiceIdentity(name: "listener")),
        ]
        let runtime = CaptureRuntime(
            clock: clock,
            source: ReplayedNowPlaying(),
            store: store,
            allowlist: InMemoryAppAllowlist(),
            credentials: credentials,
            serviceAdapters: adapters,
            settings: CaptureSettings(scrobblingEnabled: enabled),
            catalogueSearchTimeout: timeout,
        )
        await runtime.start()
        if let current {
            _ = try await runtime.linkVerified(
                kind: current,
                credential: "session-key",
                identity: ServiceIdentity(name: "listener"),
            )
        }
        runtime.catalogueSearch?.beginSession()
        return Harness(
            database: database,
            store: store,
            clock: clock,
            runtime: runtime,
            transport: transport,
        )
    }

    private func standardTransport(failures: [String: Int] = [:]) -> CatalogueTransport {
        CatalogueTransport(failures: failures) { parameters in
            switch parameters["method"] {
            case "artist.search":
                artistSearchResponse(oneArtist("Blondie"))
            case "album.search":
                albumSearchResponse(oneAlbum("Parallel Lines", artist: "Blondie"))
            case "track.search":
                trackSearchResponse(oneTrack("Heart of Glass", artist: "Blondie"))
            case "user.getlovedtracks":
                lovedTracksResponse(
                    [(title: "Heart of Glass", artist: "Blondie", url: nil)],
                    page: 1,
                    totalPages: 1,
                )
            case "auth.getToken":
                lastFMTokenResponse()
            case "track.updateNowPlaying":
                lastFMEmptyResponse()
            case "track.scrobble":
                lastFMScrobbleResponse(codes: [0])
            default:
                HTTPResponse(statusCode: 404, body: Data())
            }
        }
    }

    private func waitSettled(_ harness: Harness) async -> Bool {
        await catalogueWaitUntil {
            harness.search.hasSearched && !harness.search.isSearching
        }
    }

    // MARK: - Credentials and scope

    @Test func catalogueReadsNeedAppCredentialsButNoUserConnection() async throws {
        let transport = standardTransport()
        let harness = try await makeHarness(transport: transport, current: nil, timeout: 1)
        let model = try harness.model

        await updateQueryAndAdvanceDebounce(harness.clock, model, "blo")
        #expect(await waitSettled(harness))

        #expect(harness.search.group(.artists)?.phase == .ready)
        #expect(harness.search.group(.albums)?.phase == .ready)
        #expect(harness.search.group(.tracks)?.phase == .ready)
        #expect(harness.search.group(.loved)?.phase == .unavailable)
        #expect(harness.search.group(.loved)?.detail?.contains("Last.fm") == true)
        #expect(harness.search.appCredentialProblem == nil)

        let methods = await transport.methods()
        #expect(methods.sorted() == ["album.search", "artist.search", "track.search"])
        for parameters in await transport.parameters() {
            #expect(parameters["api_key"] == lastFMTestCredentials.apiKey)
            #expect(parameters["sk"] == nil)
        }
        for request in await transport.requests {
            #expect(request.url.absoluteString == "https://ws.audioscrobbler.com/2.0/")
        }
    }

    @Test func missingAppCredentialsShowTheSettingsRemedyWithoutARequest() async throws {
        let transport = standardTransport()
        let harness = try await makeHarness(
            transport: transport,
            appCredentials: LastFMAppCredentials(apiKey: "", sharedSecret: ""),
            timeout: 1,
        )
        let model = try harness.model

        await updateQueryAndAdvanceDebounce(harness.clock, model, "blo")
        #expect(await waitSettled(harness))

        for kind in CatalogueGroupKind.allCases {
            guard case let .failed(failure) = harness.search.group(kind)?.phase else {
                Issue.record("\(kind) should have failed")
                continue
            }
            #expect(failure == .appCredentials(.missing))
            #expect(failure.needsSettings)
        }
        #expect(harness.search.appCredentialProblem == .missing)
        #expect(await transport.requestCount() == 0)
    }

    @Test func rejectedAppCredentialsNameTheProblemAndLeaveOtherGroupsAlone() async throws {
        let transport = CatalogueTransport { parameters in
            switch parameters["method"] {
            case "artist.search":
                lastFMErrorResponse(code: 10, message: "Invalid API key")
            case "album.search":
                albumSearchResponse(oneAlbum("Parallel Lines", artist: "Blondie"))
            case "track.search":
                trackSearchResponse(oneTrack("Heart of Glass", artist: "Blondie"))
            default:
                lovedTracksResponse([], page: 1, totalPages: 1)
            }
        }
        let harness = try await makeHarness(transport: transport, timeout: 1)
        let model = try harness.model

        await updateQueryAndAdvanceDebounce(harness.clock, model, "blo")
        #expect(await waitSettled(harness))

        #expect(harness.search.group(.artists)?.phase == .failed(.appCredentials(.invalidKey)))
        #expect(harness.search.group(.albums)?.phase == .ready)
        #expect(harness.search.group(.tracks)?.phase == .ready)
        #expect(harness.search.appCredentialProblem == .invalidKey)
        #expect(harness.runtime.state.lastFMAppCredentialProblem == nil)
    }

    // MARK: - Request bounds

    @Test func fourGroupsRunAtOnceWithTenResultsAndBoundedPages() async throws {
        let transport = CatalogueTransport(
            hold: { _ in true },
            handler: { parameters in
                switch parameters["method"] {
                case "artist.search":
                    artistSearchResponse(oneArtist("Blondie"))
                case "album.search":
                    albumSearchResponse(oneAlbum("Parallel Lines", artist: "Blondie"))
                case "track.search":
                    trackSearchResponse(oneTrack("Heart of Glass", artist: "Blondie"))
                default:
                    lovedTracksResponse(
                        [(title: "Heart of Glass", artist: "Blondie", url: nil)],
                        page: 1,
                        totalPages: 1,
                    )
                }
            },
        )
        let harness = try await makeHarness(transport: transport, timeout: 1)
        let model = try harness.model

        await updateQueryAndAdvanceDebounce(harness.clock, model, "blo")
        #expect(await transport.waitUntilEntered(4))
        #expect(await transport.maxConcurrentRequests() == 4)
        #expect(CatalogueSearchReadModel.resultsPerGroup == 10)
        #expect(CatalogueSearchReadModel.lovedPageSize == 200)
        #expect(CatalogueSearchReadModel.defaultTimeout == 15)

        await transport.release()
        #expect(await waitSettled(harness))

        let parameters = await transport.parameters()
        #expect(parameters.count == 4)
        for entry in parameters {
            if entry["method"] == "user.getlovedtracks" {
                #expect(entry["limit"] == "200")
                #expect(entry["page"] == "1")
            } else {
                #expect(entry["limit"] == "10")
            }
        }
    }

    @Test func theDebounceWaitsThreeHundredMillisecondsAndRequiresTwoCharacters() async throws {
        let transport = standardTransport()
        let harness = try await makeHarness(transport: transport, timeout: 1)
        let model = try harness.model

        model.updateQuery("a")
        await turnMainActor()
        #expect(harness.clock.sleeperCount == 0)
        #expect(await transport.requestCount() == 0)

        model.updateQuery("bl")
        #expect(await catalogueWaitUntil { harness.clock.sleeperCount > 0 })
        #expect(await transport.requestCount() == 0)

        harness.clock.advance(to: harness.clock.now.addingTimeInterval(0.1))
        await turnMainActor()
        #expect(await transport.requestCount() == 0)

        harness.clock.advance(to: harness.clock.now.addingTimeInterval(0.2))
        #expect(await waitSettled(harness))
        #expect(await transport.requestCount() == 4)
    }

    @Test func theSameQuerySendsNewRequestsEveryTime() async throws {
        let transport = standardTransport()
        let harness = try await makeHarness(transport: transport, timeout: 1)
        let model = try harness.model

        await updateQueryAndAdvanceDebounce(harness.clock, model, "blo")
        #expect(await waitSettled(harness))
        let firstCount = await transport.requestCount()
        #expect(firstCount == 4)

        model.updateQuery("blo")
        #expect(await catalogueWaitUntil { harness.clock.sleeperCount > 0 })
        harness.clock.advance(to: harness.clock.now.addingTimeInterval(0.3))
        #expect(await waitSettled(harness))

        #expect(await transport.requestCount() == firstCount * 2)
    }

    @Test func changingAppCredentialsRefreshesEveryGroup() async throws {
        let transport = standardTransport()
        let harness = try await makeHarness(transport: transport, timeout: 1)
        let model = try harness.model

        await updateQueryAndAdvanceDebounce(harness.clock, model, "blo")
        #expect(await waitSettled(harness))
        let firstCount = await transport.requestCount()
        #expect(firstCount == 4)

        try await harness.runtime.saveLastFMAppCredentialOverride(
            apiKey: "new-key",
            sharedSecret: "new-secret",
        )
        #expect(await waitSettled(harness))

        // One auth.getToken validation plus a full four-group refresh, all
        // signed with the newly saved app key.
        let postSave = await Array((transport.parameters()).dropFirst(firstCount))
        #expect(postSave.count == 5)
        #expect(postSave.allSatisfy { $0["api_key"] == "new-key" })
    }

    // MARK: - Cancellation

    @Test func aNewQueryCancelsTheOldAndIgnoresLateReplies() async throws {
        let transport = CatalogueTransport(
            hold: { parameters in
                guard parameters["method"] != "user.getlovedtracks" else { return false }
                let query = parameters["artist"] ?? parameters["album"] ?? parameters["track"] ?? ""
                return query == "blo"
            },
            handler: { parameters in
                let query = parameters["artist"] ?? parameters["album"] ?? parameters["track"] ?? "hea"
                switch parameters["method"] {
                case "artist.search":
                    return artistSearchResponse(oneArtist("\(query) artist"))
                case "album.search":
                    return albumSearchResponse(oneAlbum("\(query) album", artist: query))
                case "track.search":
                    return trackSearchResponse(oneTrack("\(query) track", artist: query))
                default:
                    return lovedTracksResponse(
                        [(title: "\(query) loved", artist: query, url: nil)],
                        page: 1,
                        totalPages: 1,
                    )
                }
            },
        )
        let harness = try await makeHarness(transport: transport, timeout: 1)
        let model = try harness.model

        await updateQueryAndAdvanceDebounce(harness.clock, model, "blo")
        #expect(await transport.waitUntilEntered(2))

        model.updateQuery("hea")
        #expect(await catalogueWaitUntil { harness.clock.sleeperCount > 0 })
        harness.clock.advance(to: harness.clock.now.addingTimeInterval(0.3))
        #expect(await waitSettled(harness))
        #expect(harness.search.query == "hea")
        #expect(harness.search.group(.artists)?.rows.first?.title == "hea artist")

        await transport.release()
        await turnMainActor(50)

        #expect(harness.search.query == "hea")
        #expect(harness.search.group(.artists)?.rows.first?.title == "hea artist")
        #expect(harness.search.group(.tracks)?.rows.first?.title == "hea track")
        #expect(harness.search.group(.artists)?.rows.contains { $0.title.contains("blo") } == false)
        #expect(harness.search.group(.albums)?.rows.contains { $0.title.contains("blo") } == false)
    }

    @Test func closingAndDeactivatingStopOwnedWork() async throws {
        let transport = CatalogueTransport(
            hold: { _ in true },
            handler: { parameters in
                switch parameters["method"] {
                case "artist.search":
                    artistSearchResponse(oneArtist("Blondie"))
                case "album.search":
                    albumSearchResponse(oneAlbum("Parallel Lines", artist: "Blondie"))
                case "track.search":
                    trackSearchResponse(oneTrack("Heart of Glass", artist: "Blondie"))
                default:
                    lovedTracksResponse([], page: 1, totalPages: 1)
                }
            },
        )
        let harness = try await makeHarness(transport: transport, timeout: 1)
        let model = try harness.model

        await updateQueryAndAdvanceDebounce(harness.clock, model, "blo")
        #expect(await transport.waitUntilEntered(4))
        #expect(harness.search.isSearching)

        model.endSession()
        #expect(harness.search.query.isEmpty)
        #expect(harness.search.groups.allSatisfy { $0.phase == .idle })
        #expect(!harness.search.isSearching)

        await transport.release()
        await turnMainActor(50)
        #expect(harness.search.groups.allSatisfy { $0.phase == .idle })
        #expect(harness.search.resultCount == 0)

        model.activate()
        model.beginSession()
        await updateQueryAndAdvanceDebounce(harness.clock, model, "blo")
        #expect(await waitSettled(harness))

        model.deactivate()
        #expect(harness.search.query.isEmpty)
        #expect(harness.search.groups.allSatisfy { $0.phase == .idle })
    }

    @Test func duplicateEntriesAreDeduplicatedBeforeTheLimit() async throws {
        let transport = CatalogueTransport { parameters in
            switch parameters["method"] {
            case "artist.search":
                return artistSearchResponse(
                    Array(
                        repeating: (
                            name: "Heart Artist",
                            url: "https://www.last.fm/music/Heart+Artist",
                        ),
                        count: 10,
                    ),
                )
            case "album.search":
                return albumSearchResponse(oneAlbum("Parallel Lines", artist: "Blondie"))
            case "track.search":
                return trackSearchResponse(oneTrack("Heart of Glass", artist: "Blondie"))
            default:
                let page = Int(parameters["page"] ?? "1") ?? 1
                if page == 1 {
                    var entries = Array(
                        repeating: (
                            title: "Heart 1",
                            artist: "Blondie",
                            url: String?.none,
                        ),
                        count: 9,
                    )
                    entries.append((title: "Other 1", artist: "Blondie", url: nil))
                    return lovedTracksResponse(entries, page: 1, totalPages: 2)
                }
                return lovedTracksResponse(
                    [(title: "Heart 2", artist: "Blondie", url: nil)],
                    page: 2,
                    totalPages: 2,
                )
            }
        }
        let harness = try await makeHarness(transport: transport, timeout: 1)
        let model = try harness.model

        await updateQueryAndAdvanceDebounce(harness.clock, model, "heart")
        #expect(await waitSettled(harness))

        let artists = try #require(harness.search.group(.artists))
        #expect(artists.phase == .ready)
        #expect(artists.rows.count == 1)
        #expect(artists.rows.map(\.id) == [artists.rows[0].id])

        let loved = try #require(harness.search.group(.loved))
        #expect(loved.phase == .ready)
        #expect(loved.rows.count == 2)
        #expect(Set(loved.rows.map(\.id)).count == 2)
        let lovedRequests = await transport.parameters().filter { $0["method"] == "user.getlovedtracks" }
        #expect(lovedRequests.compactMap { $0["page"] } == ["1", "2"])
    }

    // MARK: - Group isolation and timeouts

    @Test func oneGroupFailureLeavesTheOtherGroupsIntact() async throws {
        let transport = CatalogueTransport { parameters in
            switch parameters["method"] {
            case "artist.search":
                throw URLError(.notConnectedToInternet)
            case "album.search":
                albumSearchResponse(oneAlbum("Parallel Lines", artist: "Blondie"))
            case "track.search":
                trackSearchResponse(oneTrack("Heart of Glass", artist: "Blondie"))
            default:
                lovedTracksResponse([], page: 1, totalPages: 1)
            }
        }
        let harness = try await makeHarness(transport: transport, timeout: 1)
        let model = try harness.model

        await updateQueryAndAdvanceDebounce(harness.clock, model, "blo")
        #expect(await waitSettled(harness))

        #expect(harness.search.group(.artists)?.phase == .failed(.offline))
        #expect(harness.search.group(.albums)?.phase == .ready)
        #expect(harness.search.group(.tracks)?.phase == .ready)
        #expect(harness.search.group(.loved)?.phase == .empty)
    }

    @Test func tryAgainReadsAFailedGroupAndReplacesTheFailure() async throws {
        let transport = standardTransport(failures: ["artist.search": 1])
        let harness = try await makeHarness(transport: transport, timeout: 1)
        let model = try harness.model

        await updateQueryAndAdvanceDebounce(harness.clock, model, "blo")
        #expect(await waitSettled(harness))
        #expect(harness.search.group(.artists)?.phase == .failed(.offline))

        model.retry()
        #expect(await waitSettled(harness))

        let artists = try #require(harness.search.group(.artists))
        #expect(artists.phase == .ready)
        #expect(artists.rows.count == 1)
        let artistRequests = await transport.parameters().filter { $0["method"] == "artist.search" }
        #expect(artistRequests.count == 2)
    }

    @Test func aTimedOutGroupFailsWithoutHoldingTheOthers() async throws {
        let transport = CatalogueTransport(
            hold: { $0["method"] == "album.search" },
            handler: { parameters in
                switch parameters["method"] {
                case "artist.search":
                    artistSearchResponse(oneArtist("Blondie"))
                case "album.search":
                    albumSearchResponse(oneAlbum("Parallel Lines", artist: "Blondie"))
                case "track.search":
                    trackSearchResponse(oneTrack("Heart of Glass", artist: "Blondie"))
                default:
                    lovedTracksResponse([], page: 1, totalPages: 1)
                }
            },
        )
        let harness = try await makeHarness(transport: transport, timeout: 0.15)
        let model = try harness.model

        await updateQueryAndAdvanceDebounce(harness.clock, model, "blo")
        #expect(await waitSettled(harness))

        #expect(harness.search.group(.artists)?.phase == .ready)
        #expect(harness.search.group(.tracks)?.phase == .ready)
        #expect(harness.search.group(.albums)?.phase == .failed(.timedOut))

        await transport.release()
    }

    // MARK: - Loved results

    private func lovedTransport(totalPages: Int) -> CatalogueTransport {
        CatalogueTransport { parameters in
            switch parameters["method"] {
            case "artist.search":
                return artistSearchResponse(oneArtist("Blondie"))
            case "album.search":
                return albumSearchResponse(oneAlbum("Parallel Lines", artist: "Blondie"))
            case "track.search":
                return trackSearchResponse(oneTrack("Heart of Glass", artist: "Blondie"))
            default:
                let page = Int(parameters["page"] ?? "1") ?? 1
                return lovedTracksResponse(
                    [
                        (title: "Heart \(page) A", artist: "Blondie", url: nil),
                        (title: "Heart \(page) B", artist: "Blondie", url: nil),
                        (title: "Other \(page)", artist: "Blondie", url: nil),
                    ],
                    page: page,
                    totalPages: totalPages,
                )
            }
        }
    }

    @Test func lovedReadsAtMostFivePagesAndSaysWhenTheLimitWasReached() async throws {
        let transport = lovedTransport(totalPages: 9)
        let harness = try await makeHarness(transport: transport, timeout: 1)
        let model = try harness.model

        await updateQueryAndAdvanceDebounce(harness.clock, model, "heart")
        #expect(await waitSettled(harness))

        let loved = try #require(harness.search.group(.loved))
        #expect(loved.phase == .ready)
        #expect(loved.rows.count == 10)
        #expect(loved.detail?.contains("first 1,000 checked") == true)
        #expect(loved.detail?.contains("listener") == true)

        let lovedRequests = await transport.parameters().filter { $0["method"] == "user.getlovedtracks" }
        #expect(lovedRequests.count == 5)
        #expect(lovedRequests.compactMap { $0["page"] } == ["1", "2", "3", "4", "5"])
        #expect(lovedRequests.allSatisfy { $0["limit"] == "200" })
    }

    @Test func lovedReportsTheLimitEvenWithFewerThanTenMatches() async throws {
        let transport = CatalogueTransport { parameters in
            switch parameters["method"] {
            case "artist.search":
                return artistSearchResponse(oneArtist("Blondie"))
            case "album.search":
                return albumSearchResponse(oneAlbum("Parallel Lines", artist: "Blondie"))
            case "track.search":
                return trackSearchResponse(oneTrack("Heart of Glass", artist: "Blondie"))
            default:
                let page = Int(parameters["page"] ?? "1") ?? 1
                return lovedTracksResponse(
                    [(title: "Heart \(page)", artist: "Blondie", url: nil)],
                    page: page,
                    totalPages: 9,
                )
            }
        }
        let harness = try await makeHarness(transport: transport, timeout: 1)
        let model = try harness.model

        await updateQueryAndAdvanceDebounce(harness.clock, model, "heart")
        #expect(await waitSettled(harness))

        let loved = try #require(harness.search.group(.loved))
        #expect(loved.phase == .ready)
        #expect(loved.rows.count == 5)
        #expect(loved.detail?.contains("first 1,000 checked") == true)

        let lovedRequests = await transport.parameters().filter { $0["method"] == "user.getlovedtracks" }
        #expect(lovedRequests.compactMap { $0["page"] } == ["1", "2", "3", "4", "5"])
    }

    @Test func lovedStopsWhenTheLastPageIsReached() async throws {
        let transport = lovedTransport(totalPages: 2)
        let harness = try await makeHarness(transport: transport, timeout: 1)
        let model = try harness.model

        await updateQueryAndAdvanceDebounce(harness.clock, model, "heart")
        #expect(await waitSettled(harness))

        let loved = try #require(harness.search.group(.loved))
        #expect(loved.phase == .ready)
        #expect(loved.rows.count == 4)
        #expect(loved.detail == "Loved by listener")

        let lovedRequests = await transport.parameters().filter { $0["method"] == "user.getlovedtracks" }
        #expect(lovedRequests.compactMap { $0["page"] } == ["1", "2"])
    }

    @Test func lovedExplainsWhenTheCurrentConnectionIsNotLastFM() async throws {
        let transport = standardTransport()
        let harness = try await makeHarness(transport: transport, current: .listenBrainz, timeout: 1)
        let model = try harness.model

        await updateQueryAndAdvanceDebounce(harness.clock, model, "blo")
        #expect(await waitSettled(harness))

        let loved = try #require(harness.search.group(.loved))
        #expect(loved.phase == .unavailable)
        #expect(loved.detail?.contains("Last.fm") == true)
        #expect(loved.rows.isEmpty)

        let methods = await transport.methods()
        #expect(!methods.contains("user.getlovedtracks"))
    }

    @Test func aConnectionChangeRestartsTheQueryAndDropsTheOldLovedReply() async throws {
        let transport = CatalogueTransport(
            hold: { $0["method"] == "user.getlovedtracks" },
            handler: { parameters in
                switch parameters["method"] {
                case "artist.search":
                    artistSearchResponse(oneArtist("Blondie"))
                case "album.search":
                    albumSearchResponse(oneAlbum("Parallel Lines", artist: "Blondie"))
                case "track.search":
                    trackSearchResponse(oneTrack("Heart of Glass", artist: "Blondie"))
                default:
                    lovedTracksResponse(
                        [(title: "Heart of Glass", artist: "Blondie", url: nil)],
                        page: 1,
                        totalPages: 1,
                    )
                }
            },
        )
        let harness = try await makeHarness(transport: transport, current: .lastFM, timeout: 30)
        let listenBrainz = try await harness.runtime.linkVerified(
            kind: .listenBrainz,
            credential: "token",
            identity: ServiceIdentity(name: "listener"),
        )
        let lastFM = try #require(harness.runtime.state.connections.first { $0.kind == .lastFM })
        try await harness.runtime.setCurrentConnection(lastFM.id)
        let model = try harness.model

        await updateQueryAndAdvanceDebounce(harness.clock, model, "blo")
        #expect(await transport.waitUntilEntered(1))
        #expect(harness.search.group(.loved)?.phase == .loading)
        #expect(await catalogueWaitUntil {
            harness.search.group(.artists)?.phase == .ready
                && harness.search.group(.albums)?.phase == .ready
                && harness.search.group(.tracks)?.phase == .ready
        })
        let initialRequests = await transport.requestCount()
        #expect(initialRequests == 4)

        // A snapshot for the same current account must not restart anything.
        try await harness.runtime.setCurrentConnection(lastFM.id)
        await turnMainActor(20)
        #expect(await transport.requestCount() == initialRequests)

        try await harness.runtime.setCurrentConnection(listenBrainz.id)
        #expect(await catalogueWaitUntil {
            harness.search.group(.loved)?.phase == .unavailable && !harness.search.isSearching
        })
        #expect(harness.search.group(.loved)?.detail?.contains("ListenBrainz") == true)
        #expect(await transport.requestCount() == initialRequests)

        await transport.release()
        await turnMainActor(50)
        #expect(harness.search.group(.loved)?.phase == .unavailable)

        try await harness.runtime.setCurrentConnection(lastFM.id)
        #expect(await catalogueWaitUntil {
            harness.search.group(.loved)?.phase == .ready && !harness.search.isSearching
        })
        #expect(harness.search.group(.loved)?.detail?.contains("listener") == true)
        #expect(await transport.requestCount() == initialRequests + 1)
    }

    // MARK: - Isolation from other service roots

    @Test func lastFMRequestsKeepTheirEndpointAndSessionKeyForLibreFMAndListenBrainz() async throws {
        for current in [ServiceKind.libreFM, .listenBrainz] {
            let transport = standardTransport()
            let harness = try await makeHarness(transport: transport, current: current, timeout: 1)
            let model = try harness.model

            await updateQueryAndAdvanceDebounce(harness.clock, model, "blo")
            #expect(await waitSettled(harness))

            let requests = await transport.requests
            #expect(!requests.isEmpty)
            for request in requests {
                #expect(request.url.absoluteString == "https://ws.audioscrobbler.com/2.0/")
            }
            for parameters in await transport.parameters() {
                #expect(parameters["sk"] == nil)
            }
        }
    }

    // MARK: - Capture and delivery isolation

    @Test func aHeldSearchDoesNotBlockCaptureOrDelivery() async throws {
        let transport = CatalogueTransport(
            hold: { $0["method"] == "artist.search" },
            handler: { parameters in
                switch parameters["method"] {
                case "artist.search":
                    artistSearchResponse(oneArtist("Blondie"))
                case "album.search":
                    albumSearchResponse(oneAlbum("Parallel Lines", artist: "Blondie"))
                case "track.search":
                    trackSearchResponse(oneTrack("Heart of Glass", artist: "Blondie"))
                case "user.getlovedtracks":
                    lovedTracksResponse([], page: 1, totalPages: 1)
                case "track.updateNowPlaying":
                    lastFMEmptyResponse()
                case "track.scrobble":
                    lastFMScrobbleResponse(codes: [0])
                default:
                    HTTPResponse(statusCode: 404, body: Data())
                }
            },
        )
        let harness = try await makeHarness(transport: transport, enabled: true, timeout: 1)
        let model = try harness.model

        await updateQueryAndAdvanceDebounce(harness.clock, model, "blo")
        #expect(await transport.waitUntilEntered(1))
        #expect(harness.search.isSearching)

        let track = track(title: "Held Search Song", artist: "Blondie")
        await replay(thresholdSamples(track), on: harness.runtime, clock: harness.clock)

        #expect(await catalogueWaitUntil {
            harness.runtime.state.listens.contains { $0.processed.title == "Held Search Song" }
        })
        let listen = try #require(harness.runtime.state.listens.first { $0.processed.title == "Held Search Song" })
        let deliveries = await awaitDeliveries(harness.store, listen: listen) {
            $0.allSatisfy { $0.state == .delivered }
        }
        #expect(deliveries.map(\.state) == [.delivered])
        #expect(harness.search.isSearching, "the held search is still open")

        await transport.release()
        #expect(await waitSettled(harness))
        #expect(harness.search.group(.artists)?.phase == .ready)
    }
}
