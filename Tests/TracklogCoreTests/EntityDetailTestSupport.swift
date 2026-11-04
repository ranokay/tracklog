// swiftlint:disable file_length
import Foundation
@testable import TracklogCore

// MARK: - Transport

/// A routing transport for the detail suites. It serves Last.fm form posts,
/// iTunes searches and remote images by URL, records every request, and can
/// hold chosen requests until the test releases them.
actor EntityTransport: HTTPTransport {
    typealias Handler = @Sendable (HTTPRequest) throws -> HTTPResponse

    private let handler: Handler
    private let hold: @Sendable (HTTPRequest) -> Bool
    private var released = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var entered = 0
    private(set) var requests: [HTTPRequest] = []
    private var inFlight = 0
    private(set) var maxInFlight = 0

    init(
        hold: @escaping @Sendable (HTTPRequest) -> Bool = { _ in false },
        handler: @escaping Handler,
    ) {
        self.hold = hold
        self.handler = handler
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        if hold(request) {
            entered += 1
            if !released {
                await withCheckedContinuation { held.append($0) }
            }
        }
        return try handler(request)
    }

    func release() {
        released = true
        let waiters = held
        held.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func requestCount() -> Int {
        requests.count
    }

    func allRequests() -> [HTTPRequest] {
        requests
    }

    func requests(toHost host: String) -> [HTTPRequest] {
        requests.filter { $0.url.host?.lowercased() == host.lowercased() }
    }

    func requests(pathEndingWith suffix: String) -> [HTTPRequest] {
        requests.filter { $0.url.path.hasSuffix(suffix) }
    }

    func itunesRequests() -> [HTTPRequest] {
        requests(toHost: "itunes.apple.com")
    }

    func methods() -> [String] {
        requests.compactMap { formParameters($0)["method"] }
    }

    func waitUntilEntered(_ count: Int, timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while entered < count {
            if ContinuousClock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}

// MARK: - Responses

func entityLastFMArtistInfo(
    listeners: Int = 5,
    plays: Int = 10,
    userPlays: Int = 3,
) -> HTTPResponse {
    HTTPResponse(
        statusCode: 200,
        body: Data(
            #"""
            {"artist":{"name":"Blondie","mbid":"","url":"https://www.last.fm/music/Blondie",
            "stats":{"listeners":"\#(listeners)","playcount":"\#(plays)","userplaycount":"\#(userPlays)"}}}
            """#.utf8,
        ),
    )
}

func entityLastFMAlbumInfo(
    userPlays: Int = 7,
    image: String? = "https://images.example/album.jpg",
) -> HTTPResponse {
    let images = image.map {
        ##"[{"#text":"\##($0)","size":"extralarge"}]"##
    } ?? ##"[{"#text":"","size":"extralarge"}]"##
    return HTTPResponse(
        statusCode: 200,
        body: Data(
            #"""
            {"album":{"name":"Parallel Lines","artist":"Blondie","url":"https://www.last.fm/music/Blondie/Parallel+Lines",
            "releasedate":"23 Sep 1978, 00:00","listeners":"100","playcount":"200","userplaycount":"\#(userPlays)",
            "image":\#(images)}}
            """#.utf8,
        ),
    )
}

func entityLastFMTrackInfo(userPlays: Int = 9) -> HTTPResponse {
    HTTPResponse(
        statusCode: 200,
        body: Data(
            #"""
            {"track":{"name":"Heart of Glass","url":"https://www.last.fm/music/Blondie/_/Heart+of+Glass",
            "duration":"234000","listeners":"100","playcount":"200","userplaycount":"\#(userPlays)"}}
            """#.utf8,
        ),
    )
}

func entityLastFMError(_ code: Int, message: String) -> HTTPResponse {
    HTTPResponse(
        statusCode: 200,
        body: Data(#"{"error":\#(code),"message":"\#(message)"}"#.utf8),
    )
}

func entityImageResponse(_ data: Data?) -> HTTPResponse {
    HTTPResponse(
        statusCode: 200,
        headers: ["Content-Type": "image/png"],
        body: data ?? Data(),
    )
}

func entityITunesResponse(
    // swiftlint:disable:next large_tuple
    _ rows: [(artistID: String, artistName: String, artwork: String?)],
) -> HTTPResponse {
    let results = rows.map { row -> String in
        let art = row.artwork.map { #""artworkUrl100":"\#($0)","# } ?? ""
        return #"{"artistId":\#(row.artistID),"artistName":"\#(row.artistName)",\#(art)"collectionName":"Album"}"#
    }.joined(separator: ",")
    return HTTPResponse(
        statusCode: 200,
        body: Data(#"{"resultCount":\#(rows.count),"results":[\#(results)]}"#.utf8),
    )
}

// MARK: - Runtime composition

@MainActor
struct EntityTestComposition {
    let database: TemporaryDatabase
    let store: SQLiteListenStore
    let transport: EntityTransport
    let runtime: CaptureRuntime
    let state: TracklogAppState
    let clock: FakeClock
}

@MainActor
func entityComposition(
    database: TemporaryDatabase? = nil,
    appCredentials: LastFMAppCredentials = LastFMAppCredentials(
        apiKey: "api-key",
        sharedSecret: "secret",
    ),
    extraAdapters: [any ServiceAdapter] = [],
    listenBrainzAdapter: Bool = false,
    existingStore: SQLiteListenStore? = nil,
    runtimeStore: (any ListenStore & EntityDetailStore)? = nil,
    hold: @escaping @Sendable (HTTPRequest) -> Bool = { _ in false },
    timeout: TimeInterval = 0.2,
    handler: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse,
) async throws -> EntityTestComposition {
    let database = try database ?? TemporaryDatabase()
    let store: SQLiteListenStore = if let existingStore {
        existingStore
    } else {
        try SQLiteListenStore(url: database.url)
    }
    let transport = EntityTransport(hold: hold, handler: handler)
    var adapters: [any ServiceAdapter] = [
        LastFMAdapter(transport: transport, appCredentials: appCredentials),
    ]
    if listenBrainzAdapter {
        adapters.append(ListenBrainzAdapter(transport: transport))
    }
    adapters.append(contentsOf: extraAdapters)
    let state = TracklogAppState()
    let clock = FakeClock(historyBase)
    let runtime = CaptureRuntime(
        state: state,
        clock: clock,
        source: ReplayedNowPlaying(),
        store: runtimeStore ?? store,
        allowlist: InMemoryAppAllowlist(),
        edits: store,
        blocks: store,
        credentials: MemoryCredentialStore(),
        serviceAdapters: adapters,
        settings: CaptureSettings(scrobblingEnabled: false),
        historyPageSize: 50,
        artistImageSearch: ITunesSearchClient(transport: transport),
        imageLoader: HTTPRemoteImageLoader(transport: transport),
        entityDetailTimeout: timeout,
    )
    try await runtime.start()
    return EntityTestComposition(
        database: database,
        store: store,
        transport: transport,
        runtime: runtime,
        state: state,
        clock: clock,
    )
}

@MainActor
func waitForEntityService(
    _ state: TracklogAppState,
    timeout: Duration = .seconds(3),
    until condition: @MainActor (EntityServiceSection) -> Bool,
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if let service = state.entityDetail?.service, condition(service) {
            return true
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

@MainActor
func waitForEntityImage(
    _ state: TracklogAppState,
    timeout: Duration = .seconds(3),
    source: EntityImageSource,
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if state.entityDetail?.imageSource == source {
            return true
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

@MainActor
func waitForUnreadableOverride(
    _ state: TracklogAppState,
    timeout: Duration = .seconds(3),
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if state.entityDetail?.overrideIsUnreadable == true {
            return true
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

@MainActor
func waitForTransportRequests(
    _ transport: EntityTransport,
    atLeast count: Int,
    timeout: Duration = .seconds(3),
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await transport.requestCount() >= count {
            return true
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

// MARK: - Fixtures

func entityListen(
    title: String,
    artist: String,
    album: String = "",
    albumArtist: String = "",
    start: Date,
) -> Listen {
    let metadata = ListenMetadata(
        title: title,
        artist: artist,
        album: album,
        albumArtist: albumArtist,
    )
    return Listen(
        raw: metadata,
        processed: metadata,
        bundleID: "com.apple.Music",
        duration: 225,
        playedDuration: 225,
        startedAt: start,
        capturedAt: start.addingTimeInterval(225),
    )
}

@MainActor
func seedEntityHistory(_ store: SQLiteListenStore) async throws {
    for index in 0 ..< 3 {
        _ = try await store.insert(
            entityListen(
                title: "Heart of Glass",
                artist: "Blondie",
                album: "Parallel Lines",
                start: historyBase.addingTimeInterval(Double(index) * 60),
            ),
        )
    }
    for index in 0 ..< 2 {
        _ = try await store.insert(
            entityListen(
                title: "Once in a Lifetime",
                artist: "Talking Heads",
                album: "Remain in Light",
                start: historyBase.addingTimeInterval(600 + Double(index) * 60),
            ),
        )
    }
    _ = try await store.insert(
        entityListen(
            title: "Dreams",
            artist: "Fleetwood Mac",
            album: "Rumours",
            start: historyBase.addingTimeInterval(1_200),
        ),
    )
}

// MARK: - Failing and holding store wrappers

/// A real store whose local detail read fails a fixed number of times. Every
/// other read and write still reaches SQLite.
actor FailingEntityDetailStore: ListenStore, TrackHistoryStore, EntityDetailStore, ConnectionStore {
    private let base: SQLiteListenStore
    private var failuresRemaining: Int

    init(_ base: SQLiteListenStore, failures: Int) {
        self.base = base
        failuresRemaining = failures
    }

    func failNextDetailRead() {
        failuresRemaining += 1
    }

    func insert(_ listen: Listen) async throws -> Listen? {
        try await base.insert(listen)
    }

    func page(limit: Int, before cursor: ListenCursor?) async throws -> [Listen] {
        try await base.page(limit: limit, before: cursor)
    }

    func count() async throws -> Int {
        try await base.count()
    }

    func count(in range: Range<Date>) async throws -> Int {
        try await base.count(in: range)
    }

    func entityLocalDetail(
        kind: EntityKind,
        key: String,
        topTrackLimit: Int,
    ) async throws -> EntityLocalDetail {
        guard failuresRemaining == 0 else {
            failuresRemaining -= 1
            throw DatabaseError.sqlite("simulated detail read failure")
        }
        return try await base.entityLocalDetail(
            kind: kind,
            key: key,
            topTrackLimit: topTrackLimit,
        )
    }

    func trackHistorySummary(matching key: String) async throws -> TrackHistorySummary {
        try await base.trackHistorySummary(matching: key)
    }

    func trackHistoryPage(
        matching key: String,
        limit: Int,
        before cursor: ListenCursor?,
    ) async throws -> [Listen] {
        try await base.trackHistoryPage(matching: key, limit: limit, before: cursor)
    }

    func connections() async throws -> [Connection] {
        try await base.connections()
    }

    func save(_ connection: Connection) async throws -> Connection {
        try await base.save(connection)
    }

    func deleteConnection(id: Int64) async throws {
        try await base.deleteConnection(id: id)
    }

    func currentConnectionID() async throws -> Int64? {
        try await base.currentConnectionID()
    }

    func setCurrentConnectionID(_ id: Int64?) async throws {
        try await base.setCurrentConnectionID(id)
    }

    func imageOverrides() async throws -> [ImageOverride] {
        try await base.imageOverrides()
    }

    func imageOverride(kind: EntityKind, key: String) async throws -> ImageOverride? {
        try await base.imageOverride(kind: kind, key: key)
    }

    func saveImageOverride(_ override: ImageOverride, artwork: StoredArtwork) async throws {
        try await base.saveImageOverride(override, artwork: artwork)
    }

    func removeImageOverride(kind: EntityKind, key: String) async throws {
        try await base.removeImageOverride(kind: kind, key: key)
    }

    func artistImageCache(forArtist key: String) async throws -> ArtistImageCacheEntry? {
        try await base.artistImageCache(forArtist: key)
    }

    func saveArtistImageCache(
        _ entry: ArtistImageCacheEntry,
        artwork: StoredArtwork?,
    ) async throws {
        try await base.saveArtistImageCache(entry, artwork: artwork)
    }

    func pruneExpiredArtistImageCache(now: Date) async throws {
        try await base.pruneExpiredArtistImageCache(now: now)
    }
}

/// A real store whose override list read can be held, to prove deactivation
/// owns the activation load.
actor HoldingOverridesStore: ListenStore, TrackHistoryStore, EntityDetailStore, ConnectionStore {
    private let base: SQLiteListenStore
    private let gate: ChartHoldGate

    init(_ base: SQLiteListenStore, gate: ChartHoldGate) {
        self.base = base
        self.gate = gate
    }

    func insert(_ listen: Listen) async throws -> Listen? {
        try await base.insert(listen)
    }

    func page(limit: Int, before cursor: ListenCursor?) async throws -> [Listen] {
        try await base.page(limit: limit, before: cursor)
    }

    func count() async throws -> Int {
        try await base.count()
    }

    func count(in range: Range<Date>) async throws -> Int {
        try await base.count(in: range)
    }

    func entityLocalDetail(
        kind: EntityKind,
        key: String,
        topTrackLimit: Int,
    ) async throws -> EntityLocalDetail {
        try await base.entityLocalDetail(kind: kind, key: key, topTrackLimit: topTrackLimit)
    }

    func trackHistorySummary(matching key: String) async throws -> TrackHistorySummary {
        try await base.trackHistorySummary(matching: key)
    }

    func trackHistoryPage(
        matching key: String,
        limit: Int,
        before cursor: ListenCursor?,
    ) async throws -> [Listen] {
        try await base.trackHistoryPage(matching: key, limit: limit, before: cursor)
    }

    func connections() async throws -> [Connection] {
        try await base.connections()
    }

    func save(_ connection: Connection) async throws -> Connection {
        try await base.save(connection)
    }

    func deleteConnection(id: Int64) async throws {
        try await base.deleteConnection(id: id)
    }

    func currentConnectionID() async throws -> Int64? {
        try await base.currentConnectionID()
    }

    func setCurrentConnectionID(_ id: Int64?) async throws {
        try await base.setCurrentConnectionID(id)
    }

    func imageOverrides() async throws -> [ImageOverride] {
        await gate.enter()
        return try await base.imageOverrides()
    }

    func imageOverride(kind: EntityKind, key: String) async throws -> ImageOverride? {
        try await base.imageOverride(kind: kind, key: key)
    }

    func saveImageOverride(_ override: ImageOverride, artwork: StoredArtwork) async throws {
        try await base.saveImageOverride(override, artwork: artwork)
    }

    func removeImageOverride(kind: EntityKind, key: String) async throws {
        try await base.removeImageOverride(kind: kind, key: key)
    }

    func artistImageCache(forArtist key: String) async throws -> ArtistImageCacheEntry? {
        try await base.artistImageCache(forArtist: key)
    }

    func saveArtistImageCache(
        _ entry: ArtistImageCacheEntry,
        artwork: StoredArtwork?,
    ) async throws {
        try await base.saveArtistImageCache(entry, artwork: artwork)
    }

    func pruneExpiredArtistImageCache(now: Date) async throws {
        try await base.pruneExpiredArtistImageCache(now: now)
    }
}
