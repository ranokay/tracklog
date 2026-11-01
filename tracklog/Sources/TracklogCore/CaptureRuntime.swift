// swiftlint:disable file_length type_body_length function_body_length
import Foundation

/// The capture composition seam: one clock, one now-playing source, one
/// database. Constructed at activation and torn down at deactivation.
@MainActor
public final class CaptureRuntime {
    public let state: TracklogAppState

    let clock: any Clock
    let source: any NowPlayingSource
    let store: (any ListenStore)?
    let artworkStore: (any ArtworkStore)?
    let allowlist: any AppAllowlistStore
    let editStore: (any SimpleEditStore)?
    let blockStore: (any BlockStore)?
    let connectionService: ConnectionService?
    let deliveryStore: (any DeliveryStore)?
    let deliveryOutbox: DeliveryOutbox?
    let feedbackStore: (any FeedbackStore)?
    let feedbackAdapters: [ServiceKind: any FeedbackAdapter]
    let credentialStore: (any CredentialStore)?
    let hudSession: HUDHostSession?
    let compiledLastFMAppCredentials: LastFMAppCredentials
    let lastFMAppCredentialsValidator: (any LastFMAppCredentialValidating)?
    let persistSettings: (@MainActor (CaptureSettings) -> Void)?
    let persistAppCredentialProblem: (@MainActor (AppCredentialProblem?) -> Void)?
    let persistLastFMInvalidationPending: (@MainActor (Bool) -> Void)?
    let sendNowPlaying: (@MainActor (Track) -> Void)?
    let engine: ScrobbleEngine
    let historyPageSize: Int
    /// Core charts' one read model. Nil when the store cannot aggregate local
    /// history or no credential store exists, which is only a test/harness
    /// composition.
    public let charts: ChartReadModel?

    var started = false
    /// Identifies the start that owns `started`, so a cancelled older start
    /// cannot clear a newer start's state after a stop and retry.
    var startGeneration = 0
    /// Identifies the newest history request, so a reload cannot be overwritten
    /// by an older in-flight append.
    var historyGeneration = 0
    var historyLoading = false
    var artworkIdentity: String?
    var artworkTask: Task<Void, Never>?
    var deliveryRefreshTask: Task<Void, Never>?
    /// Identifies the newest delivery read, so an older suspended read cannot
    /// overwrite a newer queue or row snapshot.
    var deliveryReloadGeneration = 0
    /// Wakes when the oldest pending delivery crosses the stuck threshold, so
    /// a quiet queue ages without requiring user activity.
    var stuckEvaluationTask: Task<Void, Never>?
    /// The activation baseline and transition bookkeeping behind every HUD
    /// event.
    var hudTracking = HUDTracking()
    private var feedRunning = false
    private var feedTask: Task<Void, Never>?
    private var feedSamples: AsyncStream<MediaSample?>.Continuation?
    var pauseTask: Task<Void, Never>?
    /// The processed identity whose feedback is loaded for the current track.
    var feedbackIdentity: String?
    /// The current track's feedback read, kept off the capture path so a slow
    /// local read never delays a sample or an artwork task.
    var feedbackLoadTask: Task<Void, Never>?
    /// Identities already read from the feedback store, so a page reload does
    /// not repeat the same read.
    var feedbackLoadedIdentities: Set<String> = []
    /// Per-identity write revisions, so a read protects the identities a local
    /// action changed without discarding untouched identities in the same read.
    var feedbackWriteRevisions: [String: Int] = [:]
    /// Serializes feedback actions in call order. A second toggle decides at
    /// execution time, after the first action has persisted.
    var feedbackChain: Task<Void, Never>?
    /// A credential change saved but the connection sign-out failed. A retry
    /// of the same save must still repair the connections.
    var lastFMInvalidationPending = false

    public init(
        state: TracklogAppState = TracklogAppState(),
        clock: any Clock,
        source: any NowPlayingSource,
        store: (any ListenStore)?,
        allowlist: any AppAllowlistStore,
        edits: (any SimpleEditStore)? = nil,
        blocks: (any BlockStore)? = nil,
        credentials: (any CredentialStore)? = nil,
        serviceAdapters: [any ServiceAdapter] = [],
        compiledLastFMAppCredentials: LastFMAppCredentials = .compiled,
        connectionLog: (@MainActor (ConnectionEvent) -> Void)? = nil,
        deliveryLog: (@MainActor (DeliveryEvent) -> Void)? = nil,
        hud: HUDHostSession? = nil,
        failure: CaptureFailure? = nil,
        settings: CaptureSettings = CaptureSettings(),
        persistSettings: (@MainActor (CaptureSettings) -> Void)? = nil,
        appCredentialProblem: AppCredentialProblem? = nil,
        persistAppCredentialProblem: (@MainActor (AppCredentialProblem?) -> Void)? = nil,
        lastFMInvalidationPending: Bool = false,
        persistLastFMInvalidationPending: (@MainActor (Bool) -> Void)? = nil,
        sendNowPlaying: (@MainActor (Track) -> Void)? = nil,
        configuration: ScrobbleEngine.Configuration = ScrobbleEngine.Configuration(),
        historyPageSize: Int = 100,
        chartSelection: ChartSelection = .standard,
        persistChartSelection: (@MainActor (ChartSelection) -> Void)? = nil,
        chartCalendar: @escaping @MainActor () -> Calendar = { ChartCalendar.current },
    ) {
        self.state = state
        self.clock = clock
        self.source = source
        self.store = store
        hudSession = hud
        credentialStore = credentials
        feedbackStore = store as? any FeedbackStore
        let feedbackAdapters = serviceAdapters.compactMap { $0 as? any FeedbackAdapter }
        var feedbackByKind: [ServiceKind: any FeedbackAdapter] = [:]
        for adapter in feedbackAdapters {
            feedbackByKind[adapter.kind] = adapter
        }
        self.feedbackAdapters = feedbackByKind
        self.compiledLastFMAppCredentials = compiledLastFMAppCredentials
        lastFMAppCredentialsValidator = serviceAdapters
            .compactMap { $0 as? any LastFMAppCredentialValidating }
            .first
        // The history store also owns the artwork tables. A fake that only
        // implements ListenStore simply has no covers.
        artworkStore = store as? any ArtworkStore
        self.allowlist = allowlist
        editStore = edits
        blockStore = blocks
        let service: ConnectionService? = if let connectionStore = store as? any ConnectionStore, let credentials {
            ConnectionService(
                store: connectionStore,
                credentials: credentials,
                deliveries: store as? any DeliveryStore,
                adapters: serviceAdapters,
                clock: clock,
                log: connectionLog ?? { _ in },
            )
        } else {
            nil
        }
        connectionService = service
        let deliveries = store as? any DeliveryStore
        deliveryStore = deliveries
        if let service, let deliveries, let credentials {
            deliveryOutbox = DeliveryOutbox(
                store: deliveries,
                connections: service,
                credentials: credentials,
                adapters: serviceAdapters.compactMap { $0 as? any DeliveryAdapter },
                feedbackAdapters: feedbackAdapters,
                clock: clock,
                log: deliveryLog ?? { _ in
                    // A runtime without a delivery log stays silent.
                },
            )
        } else {
            deliveryOutbox = nil
        }
        self.persistSettings = persistSettings
        self.persistAppCredentialProblem = persistAppCredentialProblem
        self.persistLastFMInvalidationPending = persistLastFMInvalidationPending
        self.lastFMInvalidationPending = lastFMInvalidationPending
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
        state.lastFMAppCredentialProblem = appCredentialProblem
        state.lastFMCompiledCredentialsPresent = compiledLastFMAppCredentials.isConfigured
        state.lastFMOverridePresent = false
        state.mediaStatus = source.mediaStatus

        if let chartStore = store as? any ChartStore, let credentials {
            charts = ChartReadModel(
                state: state,
                store: chartStore,
                credentials: credentials,
                serviceClients: serviceAdapters.compactMap { $0 as? any ChartServiceReading },
                artworkStore: store as? any ArtworkStore,
                clock: clock,
                calendar: chartCalendar,
                selection: chartSelection,
                persistSelection: persistChartSelection,
            )
        } else {
            charts = nil
        }

        wireOutboxCallbacks()
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
        credentials: (any CredentialStore)? = nil,
        serviceAdapters: [any ServiceAdapter] = [],
        compiledLastFMAppCredentials: LastFMAppCredentials = .compiled,
        connectionLog: (@MainActor (ConnectionEvent) -> Void)? = nil,
        deliveryLog: (@MainActor (DeliveryEvent) -> Void)? = nil,
        hud: HUDHostSession? = nil,
        persistSettings: (@MainActor (CaptureSettings) -> Void)? = nil,
        appCredentialProblem: AppCredentialProblem? = nil,
        persistAppCredentialProblem: (@MainActor (AppCredentialProblem?) -> Void)? = nil,
        lastFMInvalidationPending: Bool = false,
        persistLastFMInvalidationPending: (@MainActor (Bool) -> Void)? = nil,
        sendNowPlaying: (@MainActor (Track) -> Void)? = nil,
        configuration: ScrobbleEngine.Configuration = ScrobbleEngine.Configuration(),
        historyPageSize: Int = 100,
        chartSelection: ChartSelection = .standard,
        persistChartSelection: (@MainActor (ChartSelection) -> Void)? = nil,
        chartCalendar: @escaping @MainActor () -> Calendar = { ChartCalendar.current },
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
            credentials: credentials,
            serviceAdapters: serviceAdapters,
            compiledLastFMAppCredentials: compiledLastFMAppCredentials,
            connectionLog: connectionLog,
            deliveryLog: deliveryLog,
            hud: hud,
            failure: failure,
            settings: settings,
            persistSettings: persistSettings,
            appCredentialProblem: appCredentialProblem,
            persistAppCredentialProblem: persistAppCredentialProblem,
            lastFMInvalidationPending: lastFMInvalidationPending,
            persistLastFMInvalidationPending: persistLastFMInvalidationPending,
            sendNowPlaying: sendNowPlaying,
            configuration: configuration,
            historyPageSize: historyPageSize,
            chartSelection: chartSelection,
            persistChartSelection: persistChartSelection,
            chartCalendar: chartCalendar,
        )
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
        source.start(
            onSample: { sample in
                continuation.yield(sample)
            },
            onStatus: { [weak self] status in
                self?.applyMediaStatus(status)
            },
        )
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
        clearArtwork()
        state.nowPlaying = nil
        state.status = .idle
    }
}

private extension CaptureRuntime {
    /// Connects the outbox's UI-facing signals. Kept out of `init` so the
    /// composition setup stays one call per concern.
    func wireOutboxCallbacks() {
        deliveryOutbox?.onConnectionsChanged = { [weak self] in self?.applyConnectionSnapshot() }
        deliveryOutbox?.onDeliveryStateChanged = { [weak self] in self?.scheduleDeliveryRefresh() }
        deliveryOutbox?.onAppCredentialProblem = { [weak self] kind, problem in
            guard kind == .lastFM else { return }
            self?.noteLastFMAppCredentialProblem(problem)
        }
        deliveryOutbox?.onDeliverySucceeded = { [weak self] kind, connectionID in
            guard let self else { return }
            if kind == .lastFM {
                clearLastFMAppCredentialProblem()
            }
            noteDelivered(connectionID: connectionID)
        }
    }

    func applyMediaStatus(_ status: MediaStatus) {
        guard status != state.mediaStatus else { return }
        let wasAvailable = state.mediaStatus.isAvailable
        state.mediaStatus = status
        evaluateMediaHUD(wasAvailable: wasAvailable, isAvailable: status.isAvailable)
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

extension CaptureRuntime {
    public func start() async {
        guard !Task.isCancelled, !started else { return }
        started = true
        startGeneration += 1
        let generation = startGeneration
        state.mediaStatus = source.mediaStatus
        charts?.activate()
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

        await loadConnections()
        guard finishStart(generation) else { return }

        await loadLastFMAppCredentials()
        guard finishStart(generation) else { return }

        await replayPendingLastFMInvalidation()
        guard finishStart(generation) else { return }

        // Record the standing state before the activation drain. A queue that
        // was already stuck or a connection that already needs sign-in is
        // carried by the widget and banner, never by a launch HUD.
        primeHUDBaselines()
        scheduleStuckEvaluation()

        // Deliveries are durable and independent of the capture switches, so a
        // relaunch resumes the queue even with scrobbling off or paused.
        deliveryOutbox?.activate()

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
}

// swiftlint:enable file_length type_body_length function_body_length
