import Foundation

/// The capture composition seam: one clock, one now-playing source, one
/// database. Constructed at activation and torn down at deactivation.
@MainActor
public final class CaptureRuntime {
    public let state: TracklogAppState

    private let clock: any Clock
    private let source: any NowPlayingSource
    private let store: (any ListenStore)?
    private let persistScrobbling: (@MainActor (Bool) -> Void)?
    private let engine: ScrobbleEngine
    private let historyLimit: Int

    private var started = false
    private var feedRunning = false
    private var feedTask: Task<Void, Never>?
    private var feedSamples: AsyncStream<MediaSample?>.Continuation?

    public init(
        state: TracklogAppState = TracklogAppState(),
        clock: any Clock,
        source: any NowPlayingSource,
        store: (any ListenStore)?,
        failure: CaptureFailure? = nil,
        scrobblingEnabled: Bool = false,
        persistScrobbling: (@MainActor (Bool) -> Void)? = nil,
        configuration: ScrobbleEngine.Configuration = ScrobbleEngine.Configuration(),
        historyLimit: Int = 100
    ) {
        self.state = state
        self.clock = clock
        self.source = source
        self.store = store
        self.persistScrobbling = persistScrobbling
        self.engine = ScrobbleEngine(configuration: configuration)
        self.historyLimit = historyLimit

        state.scrobblingEnabled = scrobblingEnabled
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
        scrobblingEnabled: Bool,
        persistScrobbling: (@MainActor (Bool) -> Void)? = nil,
        configuration: ScrobbleEngine.Configuration = ScrobbleEngine.Configuration(),
        historyLimit: Int = 100
    ) -> CaptureRuntime {
        var store: SQLiteListenStore?
        var failure: CaptureFailure?
        do {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            store = try SQLiteListenStore(url: databaseURL)
        } catch {
            failure = .database(url: databaseURL, error: error)
        }
        return CaptureRuntime(
            state: state,
            clock: clock,
            source: source,
            store: store,
            failure: failure,
            scrobblingEnabled: scrobblingEnabled,
            persistScrobbling: persistScrobbling,
            configuration: configuration,
            historyLimit: historyLimit
        )
    }

    public func start() async {
        guard !started else { return }
        started = true
        state.feedAvailable = source.isAvailable

        if let store {
            do {
                let listens = try await store.recent(limit: historyLimit)
                guard started else { return }
                state.listens = listens
            } catch {
                guard started else { return }
                state.failure = .storage(error: error)
            }
        }

        guard started else { return }
        if state.scrobblingEnabled, store != nil {
            startFeed()
        }
    }

    public func stop() {
        stopFeed()
        started = false
    }

    public func setScrobblingEnabled(_ enabled: Bool) {
        guard enabled != state.scrobblingEnabled else { return }
        state.scrobblingEnabled = enabled
        persistScrobbling?(enabled)
        if enabled, store != nil, started {
            startFeed()
        } else {
            stopFeed()
        }
    }

    /// Feeds one observation through the engine and, when the threshold is
    /// crossed, into durable history. Public so tests replay samples without
    /// sleeping on a feed.
    public func ingest(_ sample: MediaSample?) async {
        guard started, state.scrobblingEnabled, let store else { return }

        // A sample without a title and artist after trimming is not a
        // candidate for now playing or history, and must not arm the engine.
        let observation: MediaSample? = if let sample, MetadataPipeline.process(sample.track) != nil {
            sample
        } else {
            nil
        }

        state.nowPlaying = observation
        let effects = engine.ingest(observation)
        state.status = engine.status

        for effect in effects {
            guard case .scrobble(let scrobble) = effect else { continue }
            await persist(scrobble, in: store)
        }
    }

    private func startFeed() {
        guard !feedRunning else { return }
        feedRunning = true

        let (samples, continuation) = AsyncStream<MediaSample?>.makeStream()
        feedSamples = continuation
        feedTask = Task { [weak self] in
            for await sample in samples {
                guard let self else { return }
                await self.ingest(sample)
            }
        }
        source.start { sample in
            continuation.yield(sample)
        }
    }

    private func stopFeed() {
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

    private func persist(_ scrobble: Scrobble, in store: any ListenStore) async {
        guard let processed = MetadataPipeline.process(scrobble.track) else { return }
        let listen = Listen(scrobble: scrobble, processed: processed, capturedAt: clock.now)

        do {
            guard let stored = try await store.insert(listen) else { return }
            state.lastListen = stored
            state.listenCount += 1
            do {
                state.listens = try await store.recent(limit: historyLimit)
            } catch {
                state.failure = .storage(error: error)
            }
        } catch {
            state.failure = .storage(error: error)
        }
    }
}
