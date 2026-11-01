// swiftlint:disable file_length
import Foundation
import TracklogCore

/// The four shelf states the harness renders and drives. The environment
/// override is read only in the harness; production never sees it.
enum HarnessDemoState: String {
    case playing
    case paused
    case off
    case feedUnavailable = "feed-unavailable"

    static var selected: HarnessDemoState {
        let raw = ProcessInfo.processInfo.environment["TRACKLOG_DEMO_STATE"] ?? ""
        return HarnessDemoState(rawValue: raw) ?? .playing
    }

    var isPlaying: Bool {
        self == .playing
    }

    var scrobblingEnabled: Bool {
        self != .off
    }

    var connectsAService: Bool {
        self != .off
    }

    var mediaStatus: MediaStatus {
        self == .feedUnavailable ? .unavailable : .legacyAvailable
    }
}

/// Deterministic content for the harness's surface shots and runtime checks.
/// Droppy never sees this: `host.environment.isHarness` is the only gate.
enum HarnessDemo {
    static let track = Track(
        title: "Heart of Glass",
        artist: "Blondie",
        album: "Parallel Lines",
        duration: 225,
        bundleID: "com.apple.Music",
    )

    @MainActor
    static func showNowPlaying(on runtime: CaptureRuntime) async {
        let state = HarnessDemoState.selected
        let chartFixture = HarnessChartFixture.selected

        if state.isPlaying {
            await runtime.ingest(
                MediaSample(
                    track: track,
                    elapsed: 72,
                    playbackRate: 1,
                    isPlaying: true,
                ),
            )
        }

        if let chartFixture {
            if chartFixture.linksLastFM {
                _ = try? await runtime.link(kind: .lastFM, credential: "demo-session")
            }
            if chartFixture.linksLibreFM {
                _ = try? await runtime.link(kind: .libreFM, credential: "demo-token")
            }
        } else if state.connectsAService {
            // One demo connection makes the pending banner, queue badge and
            // love action real instead of a screenshot-only fixture. Its
            // adapter is offline and never sends.
            _ = try? await runtime.link(kind: .listenBrainz, credential: "demo-token")
        }
        // The History shot shows the pending list as the queue badge opens it.
        runtime.state.setPendingListExpanded(true)
        if state.isPlaying {
            // The shot should show the demo cover, not the neutral sleeve.
            // Artwork is deliberately off the capture path, so wait for its
            // task instead of polling the published value.
            await runtime.waitForArtwork()
        }
    }
}

/// A scripted harness source: it emits the initial observation, then advances
/// the same track every two seconds until `stop`. That lets pause, resume,
/// cancel, undo and block be observed as real engine transitions instead of a
/// static demo view. It is never constructed outside the harness path.
@MainActor
final class HarnessDemoSource: NowPlayingSource {
    let demoState: HarnessDemoState
    private var task: Task<Void, Never>?
    private var elapsed: TimeInterval = 72
    private var sampleHandler: (@MainActor (MediaSample?) -> Void)?

    init(demoState: HarnessDemoState) {
        self.demoState = demoState
    }

    var mediaStatus: MediaStatus {
        demoState.mediaStatus
    }

    func start(
        onSample: @escaping @MainActor (MediaSample?) -> Void,
        onStatus: @escaping @MainActor (MediaStatus) -> Void,
    ) {
        onStatus(demoState.mediaStatus)
        guard demoState.isPlaying else { return }
        sampleHandler = onSample
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                elapsed += 2
                sampleHandler?(
                    MediaSample(
                        track: HarnessDemo.track,
                        elapsed: elapsed,
                        playbackRate: 1,
                        isPlaying: true,
                    ),
                )
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        sampleHandler = nil
    }
}

actor HarnessDemoStore: ListenStore, AppAllowlistStore, SimpleEditStore, BlockStore, ArtworkStore, ConnectionStore,
    DeliveryStore, FeedbackStore, ChartStore {
    var listens: [Listen]
    private var artworks: [String: StoredArtwork]
    private var artworkHashes: [String: String]
    private var seenApps: [SeenApp]
    private var simpleEdits: [SimpleEditRule]
    private var blockRules: [BlockRule]
    var deliveryRows: [Delivery]
    var feedbackRows: [String: TrackFeedback]
    var linkedConnections: [Connection] = []
    var chartRows: [ChartCacheKey: ChartCacheEntry] = [:]
    var currentConnection: Int64?
    var nextConnectionID: Int64 = 1
    private var nextListenID: Int64 = 1_000
    private var nextDeliveryID: Int64 = 1_000

    init() {
        let content = HarnessDemoData.makeContent()
        listens = content.listens
        artworks = content.artworks
        artworkHashes = content.hashes
        seenApps = SeededPlayers.bundleIDs.map { SeenApp(bundleID: $0, isAllowed: true) }
            + [SeenApp(bundleID: "com.apple.podcasts", isAllowed: false)]
        simpleEdits = Self.makeSimpleEdits()
        blockRules = Self.makeBlocks()
        deliveryRows = HarnessDemoData.makeDeliveries()
        let lovedIdentity = ListenMetadata(
            title: "Heart of Glass",
            artist: "Blondie",
            album: "Parallel Lines",
        ).identity
        feedbackRows = [
            lovedIdentity: TrackFeedback(
                identity: lovedIdentity,
                score: .loved,
                updatedAt: Date(timeIntervalSince1970: 1_000_000),
            ),
        ]
    }

    func feedback(for identities: [String]) async throws -> [String: TrackFeedback] {
        Dictionary(
            uniqueKeysWithValues: identities.compactMap { identity in
                feedbackRows[identity].map { (identity, $0) }
            },
        )
    }

    func setFeedback(_ score: FeedbackScore?, for identity: String, at date: Date) async throws {
        feedbackRows[identity] = score.map {
            TrackFeedback(identity: identity, score: $0, updatedAt: date)
        }
    }

    func insert(_ listen: Listen) async throws -> Listen? {
        try await insert(listen, targets: [])
    }

    func insert(_ listen: Listen, targets: [Int64]) async throws -> Listen? {
        guard !listens.contains(where: { $0.dedupKey == listen.dedupKey }) else {
            return nil
        }
        let stored = listen.stored(withID: nextListenID)
        nextListenID += 1
        listens.insert(stored, at: 0)
        for target in Set(targets).sorted() {
            deliveryRows.append(
                Delivery(
                    id: nextDeliveryID,
                    listenID: stored.id ?? 0,
                    connectionID: target,
                    serviceKind: linkedConnections.first { $0.id == target }?.kind,
                    state: .waiting,
                    attempts: 0,
                    nextAttemptAt: Date(),
                ),
            )
            nextDeliveryID += 1
        }
        return stored
    }

    func page(limit: Int, before cursor: ListenCursor?) async throws -> [Listen] {
        guard let cursor else { return Array(listens.prefix(limit)) }
        guard let index = listens.firstIndex(where: { $0.id == cursor.id }) else { return [] }
        return Array(listens[(index + 1)...].prefix(limit))
    }

    func count() async throws -> Int {
        listens.count
    }

    func artwork(for hash: String) async throws -> Data? {
        artworks[hash]?.data
    }

    func artworkHash(forTrack identity: String) async throws -> String? {
        artworkHashes[identity]
    }

    func attachArtwork(_ artwork: StoredArtwork, toTrack identity: String) async throws {
        artworks[artwork.hash] = artwork
        artworkHashes[identity] = artwork.hash
        listens = listens.map { listen in
            guard listen.raw.identity == identity, listen.artworkHash == nil else { return listen }
            return listen.withArtworkHash(artwork.hash)
        }
    }

    func apps() async throws -> [SeenApp] {
        seenApps
    }

    func isAllowed(_ bundleID: String) async throws -> Bool {
        seenApps.first { $0.bundleID == bundleID }?.isAllowed ?? false
    }

    @discardableResult
    func recordSeen(_ bundleID: String) async throws -> SeenApp? {
        let normalized = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if let existing = seenApps.first(where: { $0.bundleID == normalized }) {
            return existing
        }
        let app = SeenApp(bundleID: normalized, isAllowed: false)
        seenApps.append(app)
        return app
    }

    func setAllowed(_ bundleID: String, allowed: Bool) async throws {
        guard let index = seenApps.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        seenApps[index].isAllowed = allowed
    }

    func edits() async throws -> [SimpleEditRule] {
        SimpleEditRule.sortedForApplication(simpleEdits)
    }

    @discardableResult
    func save(_ rule: SimpleEditRule) async throws -> SimpleEditRule {
        if let error = rule.validationError {
            throw error
        }
        let id = rule.id ?? (simpleEdits.map { $0.id ?? 0 }.max() ?? 0) + 1

        // Editing a tuple removes the old row; the tuple itself is the rule's
        // identity, as it is in the real store.
        if let old = simpleEdits.firstIndex(where: { $0.id == id }),
           !Self.sameMatch(simpleEdits[old].match, rule.match) {
            simpleEdits.remove(at: old)
        }

        if let index = simpleEdits.firstIndex(where: { Self.sameMatch($0.match, rule.match) }) {
            let existingID = simpleEdits[index].id ?? id
            let stored = rule.stored(withID: existingID, savedAt: rule.savedAt)
            simpleEdits[index] = stored
            return stored
        }

        let stored = rule.stored(withID: id, savedAt: rule.savedAt)
        simpleEdits.append(stored)
        return stored
    }

    func deleteEdit(id: Int64) async throws {
        simpleEdits.removeAll { $0.id == id }
    }

    private static func sameMatch(_ lhs: SimpleEditRule.Match, _ rhs: SimpleEditRule.Match) -> Bool {
        func normalized(_ value: String?) -> String? {
            value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return normalized(lhs.track) == normalized(rhs.track)
            && normalized(lhs.artist) == normalized(rhs.artist)
            && normalized(lhs.album) == normalized(rhs.album)
            && normalized(lhs.albumArtist) == normalized(rhs.albumArtist)
    }

    func blocks() async throws -> [BlockRule] {
        BlockRule.sortedForEvaluation(blockRules)
    }

    @discardableResult
    func save(_ block: BlockRule) async throws -> BlockRule {
        if let error = block.validationError {
            throw error
        }
        let id = block.id ?? (blockRules.map { $0.id ?? 0 }.max() ?? 0) + 1

        // Editing a tuple removes the old row; the tuple itself is the block's
        // identity, as it is in the real store.
        if let old = blockRules.firstIndex(where: { $0.id == id }),
           !Self.sameBlock(blockRules[old], block) {
            blockRules.remove(at: old)
        }

        if let index = blockRules.firstIndex(where: { Self.sameBlock($0, block) }) {
            let existingID = blockRules[index].id ?? id
            let stored = block.stored(withID: existingID, savedAt: block.savedAt)
            blockRules[index] = stored
            return stored
        }

        let stored = block.stored(withID: id, savedAt: block.savedAt)
        blockRules.append(stored)
        return stored
    }

    func deleteBlock(id: Int64) async throws {
        blockRules.removeAll { $0.id == id }
    }

    private static func sameBlock(_ lhs: BlockRule, _ rhs: BlockRule) -> Bool {
        normalized(lhs.track) == normalized(rhs.track)
            && normalized(lhs.artist) == normalized(rhs.artist)
            && normalized(lhs.album) == normalized(rhs.album)
            && normalized(lhs.albumArtist) == normalized(rhs.albumArtist)
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func makeBlocks() -> [BlockRule] {
        [
            BlockRule(
                id: 1,
                artist: "The Daily",
                savedAt: Date(timeIntervalSince1970: 1_000_000),
            ),
            BlockRule(
                id: 2,
                track: "Baby Shark",
                savedAt: Date(timeIntervalSince1970: 999_500),
            ),
            BlockRule(
                id: 3,
                album: "Sleep Sounds",
                savedAt: Date(timeIntervalSince1970: 999_000),
            ),
        ]
    }

    private static func makeSimpleEdits() -> [SimpleEditRule] {
        [
            SimpleEditRule(
                id: 1,
                match: .init(track: "Heart of Glass", artist: "Blondie"),
                replacement: .init(album: "Parallel Lines"),
                savedAt: Date(timeIntervalSince1970: 1_000_000),
            ),
            SimpleEditRule(
                id: 2,
                match: .init(album: "Rumours"),
                replacement: .init(album: ""),
                savedAt: Date(timeIntervalSince1970: 999_000),
            ),
            SimpleEditRule(
                id: 3,
                match: .init(artist: "Talking Heads"),
                replacement: .init(album: "Remain in Light (Deluxe)"),
                savedAt: Date(timeIntervalSince1970: 998_000),
            ),
        ]
    }
}
