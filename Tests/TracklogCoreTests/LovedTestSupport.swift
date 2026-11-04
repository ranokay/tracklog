import Foundation
@testable import TracklogCore

// MARK: - Transport

/// A routing transport for the Loved suites. Every request is recorded, a
/// chosen subset can be held open, and the handler decides the answer.
actor LovedTransport: HTTPTransport {
    typealias Handler = @Sendable (HTTPRequest) async throws -> HTTPResponse

    private let hold: @Sendable (HTTPRequest) -> Bool
    private let handler: Handler
    private(set) var requests: [HTTPRequest] = []
    private var entered = 0
    private var released = false
    private var held: [CheckedContinuation<Void, Never>] = []

    init(
        hold: @escaping @Sendable (HTTPRequest) -> Bool = { _ in false },
        handler: @escaping Handler,
    ) {
        self.hold = hold
        self.handler = handler
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        if hold(request) {
            entered += 1
            if !released {
                await withCheckedContinuation { held.append($0) }
            }
        }
        return try await handler(request)
    }

    func release() {
        released = true
        let waiters = held
        held.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilEntered(_ count: Int = 1, timeout: Duration = .seconds(3)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while entered < count {
            if ContinuousClock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    func requestCount() -> Int {
        requests.count
    }

    func allRequests() -> [HTTPRequest] {
        requests
    }

    func requests(matching predicate: @Sendable (HTTPRequest) -> Bool) -> [HTTPRequest] {
        requests.filter(predicate)
    }
}

/// Mutable read outcome for a test that needs a failure and then a recovery.
actor LovedReadMode {
    enum Mode: Equatable, Sendable {
        case success
        case unauthorized
        case rateLimited(seconds: Int)
        case serverError
    }

    private var value: Mode = .success

    func set(_ mode: Mode) {
        value = mode
    }

    func current() -> Mode {
        value
    }
}

/// Counts how many times one page was requested, for re-read scenarios.
actor LovedPageCounter {
    private var counts: [Int: Int] = [:]

    func next(_ page: Int) -> Int {
        let value = (counts[page] ?? 0) + 1
        counts[page] = value
        return value
    }
}

/// A synchronous counter for a transport's hold predicate. The predicate runs
/// on the actor, so a small lock keeps “hold the second request” exact.
final class LovedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

// MARK: - Fixtures

struct LovedLastFMRow {
    let title: String
    let artist: String
    let mbid: String

    init(_ title: String, artist: String = "Example Artist", mbid: String = "") {
        self.title = title
        self.artist = artist
        self.mbid = mbid
    }
}

func lovedLastFMResponse(
    _ rows: [LovedLastFMRow],
    page: Int,
    totalPages: Int,
    omitted: Int = 0,
) -> HTTPResponse {
    var tracks = rows.map { row -> [String: Any] in
        [
            "name": row.title,
            "mbid": row.mbid,
            "artist": ["name": row.artist],
            "url": "https://www.last.fm/music/Example+Artist/_/\(row.title)",
        ]
    }
    for index in 0 ..< omitted {
        // No artist name: the reader must count this entry, never invent one.
        tracks.append(
            [
                "name": "Unnamed \(index)",
                "mbid": "unnamed-\(index)",
                "artist": [String: Any](),
            ],
        )
    }
    let body: [String: Any] = [
        "lovedtracks": [
            "track": tracks,
            "@attr": [
                "page": String(page),
                "perPage": "50",
                "totalPages": String(totalPages),
            ],
        ],
    ]
    return jsonResponse(body)
}

struct LovedListenBrainzItem {
    let title: String?
    let artist: String?
    let album: String?
    let mbid: String?
    let msid: String?

    init(
        title: String?,
        artist: String? = "Example Artist",
        album: String? = "Example Album",
        mbid: String? = nil,
        msid: String? = nil,
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.mbid = mbid
        self.msid = msid
    }
}

func lovedListenBrainzResponse(
    _ items: [LovedListenBrainzItem],
    totalCount: Int,
) -> HTTPResponse {
    let feedback = items.map { item -> [String: Any] in
        var value: [String: Any] = ["score": 1]
        if let mbid = item.mbid {
            value["recording_mbid"] = mbid
        }
        if let msid = item.msid {
            value["recording_msid"] = msid
        }
        if let title = item.title, let artist = item.artist {
            value["track_metadata"] = [
                "track_name": title,
                "artist_name": artist,
                "release_name": item.album ?? "",
            ]
        }
        return value
    }
    return jsonResponse([
        "count": feedback.count,
        "offset": 0,
        "total_count": totalCount,
        "feedback": feedback,
    ])
}

func jsonResponse(_ value: Any, statusCode: Int = 200) -> HTTPResponse {
    let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
    return HTTPResponse(statusCode: statusCode, body: data)
}

func lovedLastFMError(_ code: Int) -> HTTPResponse {
    jsonResponse(["error": code, "message": "Example failure"])
}

func lovedListenBrainzEmpty() -> HTTPResponse {
    jsonResponse(["count": 0, "offset": 0, "total_count": 0, "feedback": []])
}

// MARK: - Requests

func lovedLastFMUser(_ request: HTTPRequest) -> String? {
    formParameters(request)["user"]
}

func lovedLastFMMethod(_ request: HTTPRequest) -> String? {
    formParameters(request)["method"]
}

struct LovedFeedbackQuery {
    let user: String
    let offset: Int
    let count: Int
}

func lovedFeedbackQuery(_ request: HTTPRequest) -> LovedFeedbackQuery? {
    guard let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false),
          let user = components.path.split(separator: "/").dropLast().last,
          let offset = components.queryItems?.first(where: { $0.name == "offset" })?.value,
          let count = components.queryItems?.first(where: { $0.name == "count" })?.value,
          let offsetValue = Int(offset),
          let countValue = Int(count)
    else { return nil }
    return LovedFeedbackQuery(user: String(user), offset: offsetValue, count: countValue)
}

func lovedIsFeedbackPost(_ request: HTTPRequest) -> Bool {
    request.method == .post && request.url.path.hasSuffix("/1/feedback/recording-feedback")
}

func lovedIsLookup(_ request: HTTPRequest) -> Bool {
    request.method == .get && request.url.path.hasSuffix("/1/metadata/lookup")
}

func lovedFeedbackScore(_ request: HTTPRequest) -> Int? {
    guard let body = request.body,
          let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    else { return nil }
    return object["score"] as? Int
}

func lovedFeedbackReference(_ request: HTTPRequest) -> String? {
    guard let body = request.body,
          let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    else { return nil }
    return object["recording_mbid"] as? String
}

// MARK: - Composition

@MainActor
func makeLovedRuntime(
    database: TemporaryDatabase,
    clock: FakeClock,
    transport: any HTTPTransport,
    state: TracklogAppState = TracklogAppState(),
    credentials: any CredentialStore = MemoryCredentialStore(),
    hud: HUDHostSession? = nil,
) throws -> (runtime: CaptureRuntime, store: SQLiteListenStore) {
    let store = try SQLiteListenStore(url: database.url)
    let lastFM = LastFMAdapter(transport: transport, appCredentials: lastFMTestCredentials)
    let listenBrainz = ListenBrainzAdapter(transport: transport)
    let libreFM = LibreFMAdapter(
        transport: transport,
        clientKey: "0123456789abcdef0123456789abcdef",
    )
    let runtime = CaptureRuntime(
        state: state,
        clock: clock,
        source: ReplayedNowPlaying(),
        store: store,
        allowlist: InMemoryAppAllowlist(),
        edits: store,
        blocks: store,
        credentials: credentials,
        serviceAdapters: [lastFM, listenBrainz, libreFM],
        hud: hud,
        settings: CaptureSettings(scrobblingEnabled: false),
    )
    return (runtime, store)
}

@MainActor
func lovedWaitUntil(
    timeout: Duration = .seconds(3),
    _ condition: @MainActor () -> Bool,
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        if ContinuousClock.now >= deadline {
            return false
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// Waits until the transport has recorded `count` requests. The outbox's
/// ListenBrainz spacing reads the injected clock, so a fan-out test advances
/// the fake clock once the lookup is in flight.
func lovedWaitForRequests(
    _ transport: LovedTransport,
    count: Int,
    timeout: Duration = .seconds(3),
) async -> [HTTPRequest] {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    var requests = await transport.allRequests()
    while requests.count < count {
        if ContinuousClock.now >= deadline {
            break
        }
        try? await Task.sleep(for: .milliseconds(5))
        requests = await transport.allRequests()
    }
    return requests
}

func lovedWaitForRequests(
    _ transport: LovedTransport,
    timeout: Duration = .seconds(3),
    _ condition: @Sendable ([HTTPRequest]) -> Bool,
) async -> [HTTPRequest] {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    var requests = await transport.allRequests()
    while !condition(requests) {
        if ContinuousClock.now >= deadline {
            break
        }
        try? await Task.sleep(for: .milliseconds(5))
        requests = await transport.allRequests()
    }
    return requests
}

// A credential store whose read fails, to exercise the locked-keychain case.
// The suite reuses `UnreadableCredentialStore` from DeliveryTestStores.
