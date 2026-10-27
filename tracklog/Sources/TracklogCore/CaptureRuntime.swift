import Foundation

/// The capture composition seam: one clock, one now-playing source, one
/// database. Constructed at activation and torn down at deactivation.
@MainActor
public final class CaptureRuntime {
    public let state: TracklogAppState

    let clock: any Clock
    private let source: any NowPlayingSource
    let store: (any ListenStore)?
    let allowlist: any AppAllowlistStore
    let editStore: (any SimpleEditStore)?
    let blockStore: (any BlockStore)?
    let persistSettings: (@MainActor (CaptureSettings) -> Void)?
    private let sendNowPlaying: (@MainActor (Track) -> Void)?
    let engine: ScrobbleEngine
    let historyPageSize: Int

    var started = false
    /// Identifies the start that owns `started`, so a cancelled older start
    /// cannot clear a newer start's state after a stop and retry.
    var startGeneration = 0
    /// Identifies the newest history request, so a reload cannot be overwritten
    /// by an older in-flight append.
    var historyGeneration = 0
    var historyLoading = false
    private var feedRunning = false
    private var feedTask: Task<Void, Never>?
    private var feedSamples: AsyncStream<MediaSample?>.Continuation?
    var pauseTask: Task<Void, Never>?

    public init(
        state: TracklogAppState = TracklogAppState(),
        clock: any Clock,
        source: any NowPlayingSource,
        store: (any ListenStore)?,
        allowlist: any AppAllowlistStore,
        edits: (any SimpleEditStore)? = nil,
        blocks: (any BlockStore)? = nil,
        failure: CaptureFailure? = nil,
        settings: CaptureSettings = CaptureSettings(),
        persistSettings: (@MainActor (CaptureSettings) -> Void)? = nil,
        sendNowPlaying: (@MainActor (Track) -> Void)? = nil,
        configuration: ScrobbleEngine.Configuration = ScrobbleEngine.Configuration(),
        historyPageSize: Int = 100,
    ) {
        self.state = state
        self.clock = clock
        self.source = source
        self.store = store
        self.allowlist = allowlist
        editStore = edits
        blockStore = blocks
        self.persistSettings = persistSettings
        self.sendNowPlaying = sendNowPlaying

        var engineConfiguration = configuration
        engineConfiguration.minThreshold = settings.minimumDuration
        engine = ScrobbleEngine(configuration: engineConfiguration)
        self.historyPageSize = max(1, historyPageSize)

        state.scrobblingEnabled = settings.scrobblingEnabled
        state.nowPlayingEnabled = settings.nowPlayingEnabled
        state.pausedUntil = settings.pausedUntil
        state.minimumDuration = settings.minimumDuration
        state.captureAvailable = store != nil
        state.failure = failure
        state.feedAvailable = source.isAvailable
    }

    /// Opens the real database in the droplet's container. A database that
    /// cannot open leaves the runtime with capture disabled and diagnostics,
    /// rather than failing activation.
    public static func open(
        state: TracklogAppState = TracklogAppState(),
        databaseURL: URL,
        clock: any Clock,
        source: any NowPlayingSource,
        settings: CaptureSettings = CaptureSettings(),
        persistSettings: (@MainActor (CaptureSettings) -> Void)? = nil,
        sendNowPlaying: (@MainActor (Track) -> Void)? = nil,
        configuration: ScrobbleEngine.Configuration = ScrobbleEngine.Configuration(),
        historyPageSize: Int = 100,
    ) -> CaptureRuntime {
        var store: SQLiteListenStore?
        var failure: CaptureFailure?
        do {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            store = try SQLiteListenStore(url: databaseURL)
        } catch {
            failure = .database(url: databaseURL, error: error)
        }
        let allowlist: any AppAllowlistStore = store ?? UnavailableAppAllowlist()
        return CaptureRuntime(
            state: state,
            clock: clock,
            source: source,
            store: store,
            allowlist: allowlist,
            edits: store,
            blocks: store,
            failure: failure,
            settings: settings,
            persistSettings: persistSettings,
            sendNowPlaying: sendNowPlaying,
            configuration: configuration,
            historyPageSize: historyPageSize,
        )
    }

    public func start() async {
        guard !Task.isCancelled, !started else { return }
        started = true
        startGeneration += 1
        let generation = startGeneration
        state.feedAvailable = source.isAvailable
        clearExpiredPauseOnActivation()

        if let store {
            await loadFirstPage(from: store, generation: generation)
            guard finishStart(generation) else { return }
        }

        await loadSeenApps()
        guard finishStart(generation) else { return }

        await loadSimpleEdits()
        guard finishStart(generation) else { return }

        await loadBlocks()
        guard finishStart(generation) else { return }

        if state.scrobblingEnabled, state.pausedUntil == nil, store != nil {
            startFeed()
        }
        schedulePauseExpiry()
    }

    /// Returns false when this start no longer owns the runtime. A cancelled
    /// start clears `started` only while it is still the current generation.
    private func finishStart(_ generation: Int) -> Bool {
        guard started, generation == startGeneration else { return false }
        if Task.isCancelled {
            // The switch can start the feed while the history read is
            // suspended; cancellation must stop it before releasing ownership.
            stopFeed()
            started = false
            return false
        }
        return true
    }

    public func stop() {
        pauseTask?.cancel()
        pauseTask = nil
        stopFeed()
        started = false
    }

    public func setScrobblingEnabled(_ enabled: Bool) {
        guard enabled != state.scrobblingEnabled else { return }
        state.scrobblingEnabled = enabled
        persistCurrentSettings()
        if enabled, store != nil, started, state.pausedUntil == nil {
            startFeed()
        } else {
            stopFeed()
        }
    }

    /// Moves the engine's threshold floor. The current session picks it up on
    /// its next sample; a track is never pre-filtered by its duration.
    public func setMinimumDuration(_ seconds: TimeInterval) {
        let range = CaptureSettings.minimumDurationRange
        let clamped = min(max(seconds, range.lowerBound), range.upperBound)
        guard clamped != state.minimumDuration else { return }
        state.minimumDuration = clamped
        engine.setMinimumThreshold(clamped)
        persistCurrentSettings()
    }

    /// Feeds one observation through the engine and, when the threshold is
    /// crossed, into durable history. Public so tests replay samples without
    /// sleeping on a feed.
    public func ingest(_ sample: MediaSample?) async {
        guard started, state.scrobblingEnabled, state.pausedUntil == nil, let store else { return }

        // The allowlist is a gate, not a filter: a denied app produces no now
        // playing, no history and no delivery, and its sample must not keep an
        // older allowed session alive.
        guard let sample, await isAppAllowed(sample.track.bundleID) else {
            await consume(nil, raw: nil, into: store)
            return
        }

        // The allowlist read above can suspend; pause or switch-off may have
        // landed in the meantime. Do not let the sample re-arm the engine.
        guard !Task.isCancelled, started, state.scrobblingEnabled, state.pausedUntil == nil else { return }

        // A sample the metadata pipeline rejects (no title or artist after
        // cleanup, blocks, edits and trimming) is not a candidate for now
        // playing or history, and must not arm the engine.
        guard let processed = MetadataPipeline.process(
            sample.track,
            edits: state.simpleEdits,
            blocks: state.blocks,
        ) else {
            await consume(nil, raw: nil, into: store)
            return
        }

        // Now playing shows the processed values; the engine keeps the raw
        // observation so its session identity stays the player's.
        await consume(sample.replacingMetadata(processed), raw: sample, into: store)
    }

    private func consume(
        _ displayed: MediaSample?,
        raw: MediaSample?,
        into store: any ListenStore,
    ) async {
        // The allowlist read can suspend, and pause or switch-off can land
        // while it is in flight. Re-check every gate so a stale sample cannot
        // re-arm a feed that was just stopped.
        guard started, state.scrobblingEnabled, state.pausedUntil == nil else { return }

        state.nowPlaying = displayed
        let effects = engine.ingest(raw, submitted: displayed?.track)
        state.status = engine.status

        for effect in effects {
            switch effect {
            case let .nowPlaying(track):
                // The now-playing toggle is applied at send time: with it off,
                // the widget still shows the track and the listen still
                // becomes history.
                if state.nowPlayingEnabled {
                    sendNowPlaying?(track)
                }
            case let .scrobble(scrobble):
                await persist(scrobble, in: store)
            }
        }
    }

    func startFeed() {
        guard !feedRunning else { return }
        feedRunning = true

        let (samples, continuation) = AsyncStream<MediaSample?>.makeStream()
        feedSamples = continuation
        feedTask = Task { [weak self] in
            for await sample in samples {
                guard let self else { return }
                await ingest(sample)
            }
        }
        source.start { sample in
            continuation.yield(sample)
        }
    }

    func stopFeed() {
        if feedRunning {
            feedRunning = false
            source.stop()
            feedSamples?.finish()
            feedSamples = nil
            feedTask?.cancel()
            feedTask = nil
        }
        engine.reset()
        state.nowPlaying = nil
        state.status = .idle
    }

    /// Persists one threshold-crossing listen. A write admitted before a stop
    /// or switch-off may finish, but it cannot publish history after either;
    /// nothing new is admitted.
    private func persist(_ scrobble: Scrobble, in store: any ListenStore) async {
        guard !Task.isCancelled, started, state.scrobblingEnabled else { return }
        let listen = Listen(
            scrobble: scrobble,
            processed: ListenMetadata(scrobble.submitted),
            capturedAt: clock.now,
        )

        do {
            guard let stored = try await store.insert(listen),
                  !Task.isCancelled, started, state.scrobblingEnabled
            else { return }
            state.lastListen = stored
            state.listenCount += 1
            state.historyCount += 1
            await reloadVisibleHistory(in: store)
        } catch {
            guard !Task.isCancelled, started, state.scrobblingEnabled else { return }
            state.failure = .storage(error: error)
        }
    }
}

/// A database that could not open leaves capture unavailable, so no player is
/// allowed and nothing is listed.
private struct UnavailableAppAllowlist: AppAllowlistStore {
    func apps() async throws -> [SeenApp] {
        []
    }

    func isAllowed(_: String) async throws -> Bool {
        false
    }

    func recordSeen(_: String) async throws -> SeenApp? {
        nil
    }

    func setAllowed(_: String, allowed _: Bool) async throws {}
}
