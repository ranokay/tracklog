// swiftlint:disable file_length large_tuple
import Foundation
@testable import TracklogCore

// MARK: - Transport

/// The controlled HTTP seam. Every request is recorded before the handler
/// answers, so a test can assert the exact endpoint contract and hold a
/// response open while capture or another selection runs.
actor ChartHTTPTransport: HTTPTransport {
    typealias Handler = @Sendable (HTTPRequest) async throws -> HTTPResponse

    private let handler: Handler
    private(set) var recordedRequests: [HTTPRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        recordedRequests.append(request)
        return try await handler(request)
    }

    func requestCount() -> Int {
        recordedRequests.count
    }
}

/// A credential store whose next connection read can be held and then answered
/// with nil, a value or an error. Used to prove a late credential outcome
/// cannot publish over a newer source or a deactivated read model.
actor DelayedCredentialStore: CredentialStore {
    enum ReadOutcome: Sendable {
        case value(String?)
        case failure
    }

    private let base = MemoryCredentialStore()
    private var pending: ReadOutcome?
    private var entered = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func holdNextRead(_ outcome: ReadOutcome) {
        pending = outcome
        entered = false
    }

    func waitUntilRead() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func release() {
        let continuation = releaseContinuation
        releaseContinuation = nil
        continuation?.resume()
    }

    func credential(forConnection id: Int64) async throws -> String? {
        if let outcome = pending {
            pending = nil
            entered = true
            enteredContinuation?.resume()
            enteredContinuation = nil
            await withCheckedContinuation { releaseContinuation = $0 }
            switch outcome {
            case let .value(value):
                return value
            case .failure:
                throw URLError(.cannotDecodeContentData)
            }
        }
        return try await base.credential(forConnection: id)
    }

    func saveCredential(_ credential: String, forConnection id: Int64) async throws {
        try await base.saveCredential(credential, forConnection: id)
    }

    func deleteCredential(forConnection id: Int64) async throws {
        try await base.deleteCredential(forConnection: id)
    }

    func appCredential() async throws -> String? {
        try await base.appCredential()
    }

    func saveAppCredential(_ credential: String?) async throws {
        try await base.saveAppCredential(credential)
    }
}

/// Holds only the first scan that reaches a row boundary, so a second local
/// read can complete on its own connection while the first remains suspended.
actor ChartHoldCounter {
    private var seen = 0

    func takeFirst() -> Bool {
        seen += 1
        return seen == 1
    }
}

/// A flag a test flips after a successful read, without rebuilding the
/// transport or the read model.
actor ChartFlags {
    private var failing = false
    private var failingTotal = false
    private var notReady = false

    func setFailing(_ value: Bool) {
        failing = value
    }

    func isFailing() -> Bool {
        failing
    }

    func setFailingTotal(_ value: Bool) {
        failingTotal = value
    }

    func isFailingTotal() -> Bool {
        failingTotal
    }

    func setNotReady(_ value: Bool) {
        notReady = value
    }

    func isNotReady() -> Bool {
        notReady
    }
}

/// Holds chart responses after the test asks it to, and records how many
/// requests are inside. The initial cache read must not be held.
actor ChartHoldGate {
    private var holding = false
    private var entered = 0
    private var held: [CheckedContinuation<Void, Never>] = []

    func startHolding() {
        holding = true
    }

    func enter() async {
        guard holding else { return }
        entered += 1
        await withCheckedContinuation { held.append($0) }
    }

    func waitUntilEntered(_ count: Int = 1) async {
        while entered < count {
            await Task.yield()
        }
    }

    func enteredCount() -> Int {
        entered
    }

    func release() {
        holding = false
        let waiting = held
        held.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}

// MARK: - Calendar

/// A calendar the test can move under the read model, standing in for a
/// system time-zone change.
@MainActor
final class ChartCalendarBox {
    var calendar: Calendar

    init(_ calendar: Calendar) {
        self.calendar = calendar
    }
}

func chartCalendar(_ timeZone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.firstWeekday = 2
    calendar.minimumDaysInFirstWeek = 4
    return calendar
}

func chartDate(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int = 0,
    _ minute: Int = 0,
    timeZone: TimeZone = TimeZone(identifier: "UTC")!,
) -> Date {
    var calendar = chartCalendar(timeZone)
    return calendar.date(from: DateComponents(
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute,
    )) ?? Date(timeIntervalSince1970: 0)
}

func chartSelection(
    source: ChartSourceSelection,
    period: ChartPeriod,
    type: ChartType = .artists,
    now: Date,
    calendar: Calendar,
    customStart: ChartDate? = nil,
    customEnd: ChartDate? = nil,
) -> ChartSelection {
    var selection = ChartSelection.initial(now: now, calendar: calendar)
    selection.source = source
    selection.period = period
    selection.type = type
    if let customStart {
        selection.customStart = customStart
    }
    if let customEnd {
        selection.customEnd = customEnd
    }
    return selection
}

// MARK: - Runtime composition

@MainActor
func makeChartRuntime(
    database: TemporaryDatabase,
    clock: FakeClock,
    transport: any HTTPTransport,
    state: TracklogAppState = TracklogAppState(),
    selection: ChartSelection,
    calendarBox: ChartCalendarBox,
    historyPageSize: Int = 100,
    credentials: any CredentialStore = MemoryCredentialStore(),
    scrobblingEnabled: Bool = false,
    nowPlayingEnabled: Bool = true,
    persistSelection: (@MainActor (ChartSelection) -> Void)? = nil,
    extraAdapters: [any ServiceAdapter] = [],
) -> CaptureRuntime {
    let listenBrainz = ListenBrainzAdapter(transport: transport)
    let lastFM = LastFMAdapter(transport: transport, appCredentials: lastFMTestCredentials)
    let libreFM = StubAdapter(kind: .libreFM, identity: ServiceIdentity(name: "libre-listener"))
    return CaptureRuntime.open(
        state: state,
        databaseURL: database.url,
        clock: clock,
        source: ReplayedNowPlaying(),
        settings: CaptureSettings(
            scrobblingEnabled: scrobblingEnabled,
            nowPlayingEnabled: nowPlayingEnabled,
        ),
        credentials: credentials,
        serviceAdapters: [listenBrainz, lastFM, libreFM] + extraAdapters,
        historyPageSize: historyPageSize,
        chartSelection: selection,
        persistChartSelection: persistSelection,
        chartCalendar: { calendarBox.calendar },
    )
}

// MARK: - Last.fm fixtures

func lastFMChartResponse(
    type: ChartType,
    rows: [(title: String, subtitle: String, count: Int, mbid: String)],
) -> HTTPResponse {
    var items: [[String: Any]] = []
    for (index, row) in rows.enumerated() {
        var item: [String: Any] = [
            "name": row.title,
            "playcount": String(row.count),
            "mbid": row.mbid,
            "@attr": ["rank": String(index + 1)],
        ]
        if type != .artists {
            item["artist"] = ["name": row.subtitle]
        }
        items.append(item)
    }
    let container: String
    let itemKey: String
    switch type {
    case .artists:
        container = "topartists"
        itemKey = "artist"
    case .albums:
        container = "topalbums"
        itemKey = "album"
    case .tracks:
        container = "toptracks"
        itemKey = "track"
    }
    let json: [String: Any] = [
        container: [
            itemKey: items,
            "@attr": ["total": String(items.count)],
        ],
    ]
    return chartJSONResponse(json)
}

/// The same single ranked item as a JSON object, which Last.fm can return
/// instead of a one-element array.
func lastFMSingleChartResponse(type: ChartType) -> HTTPResponse {
    var item: [String: Any] = [
        "name": "Solo \(type.displayName)",
        "playcount": "1",
        "mbid": "",
        "@attr": ["rank": "1"],
    ]
    if type != .artists {
        item["artist"] = ["name": "Solo Artist"]
    }
    let container: String
    let itemKey: String
    switch type {
    case .artists:
        container = "topartists"
        itemKey = "artist"
    case .albums:
        container = "topalbums"
        itemKey = "album"
    case .tracks:
        container = "toptracks"
        itemKey = "track"
    }
    return chartJSONResponse([container: [itemKey: item]])
}

func lastFMUserInfoResponse(name: String = "listener", playcount: Int? = nil) -> HTTPResponse {
    var user: [String: Any] = ["name": name]
    if let playcount {
        user["playcount"] = String(playcount)
    }
    return chartJSONResponse(["user": user])
}

// MARK: - ListenBrainz fixtures

func listenBrainzStatsResponse(
    type: ChartType,
    rows: [(title: String, subtitle: String, count: Int, mbid: String)],
    from: Date,
    end: Date,
    lastUpdated: Date,
) -> HTTPResponse {
    var items: [[String: Any]] = []
    for row in rows {
        switch type {
        case .artists:
            items.append([
                "artist_name": row.title,
                "artist_mbid": row.mbid,
                "listen_count": row.count,
            ])
        case .albums:
            items.append([
                "release_name": row.title,
                "release_mbid": row.mbid,
                "artist_name": row.subtitle,
                "listen_count": row.count,
            ])
        case .tracks:
            items.append([
                "track_name": row.title,
                "recording_mbid": row.mbid,
                "artist_name": row.subtitle,
                "listen_count": row.count,
            ])
        }
    }
    let key = switch type {
    case .artists: "artists"
    case .albums: "releases"
    case .tracks: "recordings"
    }
    let payload: [String: Any] = [
        key: items,
        "from_ts": Int(from.timeIntervalSince1970),
        "to_ts": Int(end.timeIntervalSince1970),
        "last_updated": Int(lastUpdated.timeIntervalSince1970),
        "range": "week",
    ]
    return chartJSONResponse(["payload": payload])
}

func listenBrainzEmptyResponse(type: ChartType) -> HTTPResponse {
    let key = switch type {
    case .artists: "artists"
    case .albums: "releases"
    case .tracks: "recordings"
    }
    return chartJSONResponse(["payload": [key: [Any](), "range": "week"]])
}

func listenBrainzCountResponse(_ count: Int) -> HTTPResponse {
    chartJSONResponse(["payload": ["count": count]])
}

func chartJSONResponse(_ value: [String: Any], statusCode: Int = 200) -> HTTPResponse {
    guard let data = try? JSONSerialization.data(withJSONObject: value) else {
        return HTTPResponse(statusCode: 500, body: Data())
    }
    return HTTPResponse(statusCode: statusCode, body: data)
}

// MARK: - Request inspection

func chartMethod(_ request: HTTPRequest) -> String {
    formParameters(request)["method"] ?? ""
}

func chartListenBrainzPath(_ request: HTTPRequest) -> String {
    request.url.path
}

func chartQueryValue(_ name: String, in request: HTTPRequest) -> String? {
    URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first { $0.name == name }?
        .value
}

func chartIsLastFMTopRequest(_ request: HTTPRequest) -> Bool {
    ["user.getTopArtists", "user.getTopAlbums", "user.getTopTracks"].contains(chartMethod(request))
}

// swiftlint:enable file_length large_tuple
