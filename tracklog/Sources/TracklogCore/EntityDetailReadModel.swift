// swiftlint:disable file_length
import Foundation

/// The one detail read model: local reads, Last.fm service reads, approximate
/// artist images and user overrides. Views publish nothing themselves.
@MainActor
// swiftlint:disable:next type_body_length
public final class EntityDetailReadModel {
    /// The stack stays bounded; the oldest page is dropped when a new page
    /// would exceed it. Back always keeps the page just left.
    public nonisolated static let maximumStackDepth = 20
    public nonisolated static let topTrackLimit = 5
    public nonisolated static let defaultTimeout: TimeInterval = 15

    private let state: TracklogAppState
    private let store: any EntityDetailStore
    private let historyStore: (any TrackHistoryStore)?
    private let artworkStore: (any ArtworkStore)?
    private let historyPageSize: Int
    private let serviceClients: [ServiceKind: any EntityServiceReading]
    private let imageSearch: (any ArtistImageSearching)?
    private let imageLoader: (any RemoteImageLoading)?
    private let clock: any Clock
    private let timeout: TimeInterval
    private let log: (@MainActor (String) -> Void)?
    /// Set by the runtime so loading a track page's rows can fill the same
    /// delivery and feedback maps History uses. It is a short closure, not a
    /// second store.
    public var onTrackListensLoaded: (@MainActor ([Listen]) async -> Void)?

    private var isActive = false
    private var stack: [EntityRequest] = []
    private var generation = 0
    private var serviceGeneration = 0
    private var localTask: Task<Void, Never>?
    private var serviceTask: Task<Void, Never>?
    private var imageTask: Task<Void, Never>?
    private var loadMoreSequence = 0
    private var serviceImageTask: Task<Void, Never>?
    private var activationLoadTask: Task<Void, Never>?
    private var pruneTask: Task<Void, Never>?
    private var lastConnectionKey = "none"

    /// How many pages Back can reach. Exposed so a composition test can prove
    /// the stack stays bounded without inspecting private storage.
    public var stackDepth: Int {
        stack.count
    }

    /// Candidates for the current page, resolved in one precedence function.
    private var overridePresent = false
    private var overrideData: Data?
    private var approximateData: Data?
    private var capturedData: Data?
    private var serviceImageData: Data?

    public init(
        state: TracklogAppState,
        store: any EntityDetailStore,
        historyStore: (any TrackHistoryStore)?,
        artworkStore: (any ArtworkStore)?,
        historyPageSize: Int,
        serviceClients: [any EntityServiceReading],
        imageSearch: (any ArtistImageSearching)?,
        imageLoader: (any RemoteImageLoading)?,
        clock: any Clock,
        timeout: TimeInterval = EntityDetailReadModel.defaultTimeout,
        log: (@MainActor (String) -> Void)? = nil,
    ) {
        self.state = state
        self.store = store
        self.historyStore = historyStore
        self.artworkStore = artworkStore
        self.historyPageSize = max(1, historyPageSize)
        var clients: [ServiceKind: any EntityServiceReading] = [:]
        for client in serviceClients {
            clients[client.kind] = client
        }
        self.serviceClients = clients
        self.imageSearch = imageSearch
        self.imageLoader = imageLoader
        self.clock = clock
        self.timeout = max(0.05, timeout)
        self.log = log
        lastConnectionKey = Self.connectionKey(state.currentConnection)
    }

    // MARK: - Lifecycle

    public func activate() {
        guard !isActive else { return }
        isActive = true
        lastConnectionKey = Self.connectionKey(state.currentConnection)
        activationLoadTask = Task { [weak self] in
            await self?.loadOverrides()
        }
        pruneTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await store.pruneExpiredArtistImageCache(now: clock.now)
            } catch {
                log?("Pruning expired artist images failed: \(error)")
            }
        }
    }

    public func deactivate() {
        guard isActive else { return }
        isActive = false
        activationLoadTask?.cancel()
        activationLoadTask = nil
        pruneTask?.cancel()
        pruneTask = nil
        cancelAll()
        generation += 1
        stack = []
        state.entityDetail = nil
        state.imageOverrides = []
        state.imageOverrideDraft = nil
        state.imageOverrideError = nil
        clearCandidates()
    }

    public func close() {
        generation += 1
        cancelAll()
        stack = []
        state.entityDetail = nil
        // A pending image draft survives a detail close: Change image… opens
        // Settings by dismissing the takeover, and the Images page must still
        // know which entity it is replacing. The draft is cleared when that
        // page finishes or the droplet deactivates.
        clearCandidates()
    }

    // MARK: - Overrides list

    public func loadOverrides() async {
        guard isActive else { return }
        do {
            let overrides = try await store.imageOverrides()
            guard isActive else { return }
            state.imageOverrides = overrides
            for override in overrides {
                _ = await artworkData(for: override.artworkHash)
            }
        } catch {
            log?("Reading image overrides failed: \(error)")
        }
    }

    // MARK: - Opening and the stack

    public func open(_ request: EntityRequest) async {
        stack = [request]
        await loadPage(request)
    }

    /// A top-track row or another in-page link. The page is added to the
    /// bounded stack; Back returns to the page it came from.
    public func push(_ request: EntityRequest) async {
        if stack.last == request {
            return
        }
        stack.append(request)
        if stack.count > Self.maximumStackDepth {
            stack.removeFirst(stack.count - Self.maximumStackDepth)
        }
        await loadPage(request)
    }

    /// Back pops one page and reloads the revealed page from scratch. From the
    /// first page it closes the detail and reveals the originating list.
    public func back() async {
        guard stack.count > 1 else {
            close()
            return
        }
        stack.removeLast()
        if let request = stack.last {
            await loadPage(request)
        }
    }

    public func reload() async {
        guard isActive, let request = stack.last, state.entityDetail != nil else { return }
        generation += 1
        let token = generation
        localTask?.cancel()
        localTask = nil
        if var detail = state.entityDetail, var track = detail.track {
            track.isLoading = true
            detail.track = track
            state.entityDetail = detail
        }
        // A reload is the same page, not a new one: keep its rows and its
        // service section while the fresh local read runs.
        startLocal(request, token: token, preservingRows: true)
        await localTask?.value
    }

    /// A connection change clears only the service section. The local section
    /// and the stack are untouched.
    public func connectionsChanged() {
        guard isActive else { return }
        let key = Self.connectionKey(state.currentConnection)
        guard key != lastConnectionKey else { return }
        lastConnectionKey = key
        guard stack.last != nil else { return }
        serviceGeneration += 1
        serviceTask?.cancel()
        serviceTask = nil
        serviceImageTask?.cancel()
        serviceImageTask = nil
        serviceImageData = nil
        guard var detail = state.entityDetail else { return }
        detail.service = .loading
        state.entityDetail = detail
        recomputeImage()
        startService()
    }

    // MARK: - Page load

    private func loadPage(_ request: EntityRequest) async {
        guard isActive else { return }
        generation += 1
        let token = generation
        cancelAll()
        clearCandidates()
        state.imageOverrideDraft = nil
        state.imageOverrideError = nil
        serviceGeneration += 1

        var opening = EntityDetail(request: request)
        if request.kind == .track {
            opening.track = TrackHistory(
                identityKey: request.key,
                title: request.title,
                artist: request.subtitle,
                album: request.album,
            )
        }
        state.entityDetail = opening

        startLocal(request, token: token, preservingRows: false)
        startService()
        await loadOverride(for: request, token: token)
        // The local section is the page's primary content; wait for it so a
        // caller that opens a page sees its data. Service and image work stay
        // in flight.
        await localTask?.value
        recomputeImage()
    }

    // swiftlint:disable:next cyclomatic_complexity
    // swiftlint:disable:next function_body_length
    private func startLocal(_ request: EntityRequest, token: Int, preservingRows: Bool) {
        let store = store
        let historyStore = historyStore
        let pageSize = historyPageSize
        localTask = Task { [weak self] in
            guard let self else { return }
            do {
                let local = try await store.entityLocalDetail(
                    kind: request.kind,
                    key: request.key,
                    topTrackLimit: request.kind == .track ? 0 : Self.topTrackLimit,
                )
                guard isCurrent(token) else { return }
                // Load the captured cover before publishing a finished local
                // read, so the service-image decision cannot race it.
                if let captured = local.capturedArtworkHash {
                    capturedData = await artworkData(for: captured)
                    guard isCurrent(token) else { return }
                }
                var detail = state.entityDetail
                detail?.local = local
                detail?.isLoadingLocal = false
                detail?.localFailure = nil
                if var track = detail?.track {
                    track.totalCount = local.count
                    track.firstListenedAt = local.firstListenedAt
                    track.lastListenedAt = local.lastListenedAt
                    track.failure = nil
                    detail?.track = track
                }
                state.entityDetail = detail

                maybeStartServiceImage()
                recomputeImage()

                if request.kind == .track, let historyStore {
                    let hasRows = !(state.entityDetail?.track?.listens.isEmpty ?? true)
                    let page = try await historyStore.trackHistoryPage(
                        matching: request.key,
                        limit: pageSize,
                        before: nil,
                    )
                    guard isCurrent(token) else { return }
                    let filled = fillingKnownArtwork(page)
                    var next = state.entityDetail
                    if var track = next?.track {
                        if preservingRows, hasRows {
                            // Refresh the top and keep every loaded older page.
                            var rows = track.listens
                            var known = Set(rows.compactMap(\.id))
                            for listen in filled where listen.id.map({ !known.contains($0) }) ?? false {
                                known.insert(listen.id ?? 0)
                                rows.append(listen)
                            }
                            rows.sort { lhs, rhs in
                                if lhs.startedAt != rhs.startedAt {
                                    return lhs.startedAt > rhs.startedAt
                                }
                                return (lhs.id ?? 0) > (rhs.id ?? 0)
                            }
                            track.listens = rows
                        } else {
                            track.listens = filled
                        }
                        track.isLoading = false
                        track.failure = nil
                        track.hasMore = local.count > track.listens.count
                        next?.track = track
                    }
                    next?.isLoadingLocal = false
                    state.entityDetail = next
                    await loadStoredArtwork(for: filled)
                    await onTrackListensLoaded?(filled)
                    if capturedData == nil,
                       let hash = filled.compactMap(\.artworkHash).first {
                        capturedData = await artworkData(for: hash)
                        recomputeImage()
                    }
                }
            } catch {
                guard isCurrent(token) else { return }
                var detail = state.entityDetail
                detail?.isLoadingLocal = false
                detail?.localFailure = .history(error: error)
                if var track = detail?.track {
                    track.isLoading = false
                    track.failure = .history(error: error)
                    detail?.track = track
                }
                state.entityDetail = detail
            }
        }
    }

    // MARK: - Track paging

    public func loadMoreTrackListens() async {
        guard isActive,
              let detail = state.entityDetail,
              var track = detail.track,
              track.hasMore,
              !track.isLoading,
              let historyStore,
              let cursor = track.listens.last.flatMap(ListenCursor.init)
        else { return }

        let token = generation
        let load = nextLoadSequence()
        track.isLoading = true
        var updated = detail
        updated.track = track
        state.entityDetail = updated
        let pageSize = historyPageSize
        defer {
            // A cancelled page read never reaches the success or catch body
            // with ownership. Release the loading flag so the next footer can
            // retry from the same cursor. A newer load owns the flag and must
            // not be cleared by this one.
            if load == loadMoreSequence,
               token == generation,
               var current = state.entityDetail,
               current.track?.isLoading == true {
                current.track?.isLoading = false
                state.entityDetail = current
            }
        }
        do {
            let page = try await fillingKnownArtwork(
                historyStore.trackHistoryPage(
                    matching: track.identityKey,
                    limit: pageSize,
                    before: cursor,
                ),
            )
            guard isCurrent(token), load == loadMoreSequence, var next = state.entityDetail else {
                return
            }
            var rows = next.track?.listens ?? []
            let totalCount = next.track?.totalCount ?? 0
            var known = Set(rows.compactMap(\.id))
            for listen in page where listen.id.map({ !known.contains($0) }) ?? false {
                known.insert(listen.id ?? 0)
                rows.append(listen)
            }
            next.track?.listens = rows
            next.track?.isLoading = false
            next.track?.hasMore = totalCount > rows.count
            state.entityDetail = next
            await loadStoredArtwork(for: page)
            await onTrackListensLoaded?(page)
        } catch {
            guard isCurrent(token), load == loadMoreSequence else { return }
            var next = state.entityDetail
            next?.track?.isLoading = false
            next?.track?.failure = .history(error: error)
            state.entityDetail = next
        }
    }

    // MARK: - Service

    // swiftlint:disable:next cyclomatic_complexity
    private func startService() {
        guard let request = stack.last else { return }
        serviceGeneration += 1
        let token = serviceGeneration
        guard let connection = state.currentConnection else {
            publishUnavailable(nil)
            return
        }
        guard connection.kind == .lastFM, let client = serviceClients[.lastFM] else {
            publishUnavailable(connection)
            return
        }
        serviceTask?.cancel()
        let timeout = timeout
        serviceTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await Self.timed(seconds: timeout) {
                do {
                    let facts = try await client.entityDetails(request, connection: connection)
                    return ServiceRead.facts(facts)
                } catch EntityServiceReadError.missing {
                    return ServiceRead.missing
                } catch let failure as EntityServiceFailure {
                    return ServiceRead.failure(failure)
                } catch {
                    return ServiceRead.failure(.offline)
                }
            }
            guard isActive, serviceGeneration == token, var detail = state.entityDetail else {
                return
            }
            switch outcome {
            case let .value(.facts(facts)):
                detail.service = .facts(facts)
                state.entityDetail = detail
                maybeStartServiceImage()
            case .value(.missing):
                detail.service = .missing(EntityServiceCopy.missing(kind: request.kind, title: request.title))
                state.entityDetail = detail
            case let .value(.failure(failure)):
                detail.service = .failed(failure)
                state.entityDetail = detail
            case .timedOut:
                detail.service = .failed(.timedOut)
                state.entityDetail = detail
            case .cancelled:
                return
            }
        }
    }

    /// The album `getInfo` image is fetched only when precedence actually
    /// reaches it: no override, no captured cover, the local read done and no
    /// copy already downloaded. A downloaded copy is kept when a higher
    /// source takes over, so removing the override restores it without a
    /// second request.
    private func maybeStartServiceImage() {
        guard let detail = state.entityDetail,
              detail.request.kind == .album,
              !detail.isLoadingLocal,
              !overridePresent,
              capturedData == nil,
              serviceImageData == nil,
              case let .facts(facts) = detail.service,
              let url = facts.artworkURL
        else { return }
        startServiceImage(url, token: serviceGeneration)
    }

    public func retryService() async {
        guard var detail = state.entityDetail else { return }
        detail.service = .loading
        state.entityDetail = detail
        serviceImageData = nil
        recomputeImage()
        startService()
    }

    private func publishUnavailable(_ connection: Connection?) {
        guard var detail = state.entityDetail else { return }
        detail.service = .unavailable(EntityServiceCopy.unavailable(connection: connection))
        state.entityDetail = detail
    }

    private func startServiceImage(_ url: URL, token: Int) {
        guard let imageLoader else { return }
        serviceImageTask?.cancel()
        let timeout = timeout
        serviceImageTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await Self.timed(seconds: timeout) {
                do {
                    let data = try await imageLoader.imageData(at: url)
                    return ServiceImageRead.image(data)
                } catch {
                    return ServiceImageRead.failure
                }
            }
            guard isActive, serviceGeneration == token, case let .value(.image(data)) = outcome, let stored = await Self.normalized(data),
                  isActive, serviceGeneration == token else { return }
            serviceImageData = stored.data
            recomputeImage()
        }
    }

    // MARK: - Approximate artist image

    public func setArtistImageLookupsEnabled(_ enabled: Bool) {
        guard state.artistImageLookupsEnabled != enabled else { return }
        state.artistImageLookupsEnabled = enabled
        artistImageLookupsSettingChanged(enabled)
    }

    /// Applies a switch value the runtime already published and persisted, so
    /// the state and the owned work cannot disagree.
    public func artistImageLookupsSettingChanged(_ enabled: Bool) {
        if !enabled {
            imageTask?.cancel()
            imageTask = nil
            approximateData = nil
            recomputeImage()
            return
        }
        guard let request = stack.last, request.kind == .artist else { return }
        startArtistImageIfNeeded(request, token: generation)
    }

    // swiftlint:disable:next cyclomatic_complexity
    // swiftlint:disable:next function_body_length
    private func startArtistImageIfNeeded(_ request: EntityRequest, token: Int) {
        guard state.artistImageLookupsEnabled,
              !overridePresent,
              let imageSearch,
              let imageLoader
        else { return }
        imageTask?.cancel()
        let store = store
        let clock = clock
        let timeout = timeout
        let key = request.key
        let artist = request.title
        imageTask = Task { [weak self] in
            guard let self else { return }
            // A fresh hit or a fresh definite miss answers without a request.
            if let cached = try? await store.artistImageCache(forArtist: key),
               cached.isFresh(now: clock.now) {
                guard isCurrent(token) else { return }
                if cached.outcome == .hit,
                   let hash = cached.artworkHash,
                   let data = await artworkData(for: hash),
                   ArtworkNormalizer.isReadable(data) {
                    approximateData = data
                    recomputeImage()
                    return
                }
                if cached.outcome == .miss {
                    return
                }
                // A stored copy that vanished or will not decode is not a
                // usable hit. Fall through to a new lookup.
            }

            let outcome = await Self.timed(seconds: timeout) {
                do {
                    let albums = try await imageSearch.albums(
                        forArtist: artist,
                        limit: ArtistImageLookup.searchLimit,
                    )
                    switch ArtistImageLookup.resolve(albums, artist: artist) {
                    case let .image(url):
                        do {
                            let data = try await imageLoader.imageData(at: url)
                            return ArtistImageRead.image(data)
                        } catch {
                            return ArtistImageRead.failure
                        }
                    case .noMatch, .ambiguous, .noArtwork:
                        return ArtistImageRead.miss
                    }
                } catch {
                    return ArtistImageRead.failure
                }
            }
            guard isCurrent(token) else { return }

            switch outcome {
            case let .value(.image(data)):
                guard let stored = await Self.normalized(data) else {
                    // A corrupt download is a failure, not a definite miss:
                    // the next open tries again and no cache row is written.
                    return
                }
                guard isCurrent(token) else { return }
                try? await store.saveArtistImageCache(
                    ArtistImageCacheEntry(
                        artistKey: key,
                        artworkHash: stored.hash,
                        outcome: .hit,
                        checkedAt: clock.now,
                    ),
                    artwork: stored,
                )
                guard isCurrent(token) else { return }
                state.artworkByHash[stored.hash] = stored.data
                approximateData = stored.data
                recomputeImage()
            case .value(.miss):
                try? await store.saveArtistImageCache(
                    ArtistImageCacheEntry(
                        artistKey: key,
                        artworkHash: nil,
                        outcome: .miss,
                        checkedAt: clock.now,
                    ),
                    artwork: nil,
                )
            case .value(.failure), .timedOut, .cancelled:
                // No cache row: the next artist page tries again.
                return
            }
        }
    }

    // MARK: - Override actions

    /// Re-encodes the choice off the main actor, stores the copy and updates
    /// every surface that shows the override. The entity is an argument, not
    /// the pending draft: the file read can outlive the page or a Replace on
    /// another row, and the save must still target the entity the user chose
    /// the file for. A draft that still names that entity is consumed; a
    /// draft for another entity is left for that page.
    public func saveOverride(
        kind: EntityKind,
        key: String,
        title: String,
        subtitle: String,
        data: Data,
    ) async throws {
        guard kind.supportsImageOverride else {
            throw ImageOverrideError.unsupportedKind
        }
        guard data.count <= ImageOverridePolicy.maximumSourceBytes else {
            throw ImageOverrideError.tooLarge
        }
        guard let stored = await Self.normalized(data) else {
            throw ImageOverrideError.unreadable
        }
        let override = ImageOverride(
            kind: kind,
            key: key,
            title: title,
            subtitle: subtitle,
            artworkHash: stored.hash,
            updatedAt: clock.now,
        )
        try await store.saveImageOverride(override, artwork: stored)
        await loadOverrides()
        applySucceeded(override: override, data: stored.data)
        if state.imageOverrideDraft?.kind == kind,
           state.imageOverrideDraft?.key == key {
            state.imageOverrideDraft = nil
        }
    }

    public func removeOverride(kind: EntityKind, key: String) async throws {
        try await store.removeImageOverride(kind: kind, key: key)
        await loadOverrides()
        guard let detail = state.entityDetail,
              detail.request.kind == kind,
              detail.request.key == key
        else { return }
        overridePresent = false
        overrideData = nil
        // The released page falls back to the next source in its own
        // precedence: the artist lookup restarts, and the album restores a
        // captured cover or the service image it already downloaded, or
        // starts the service image if the override was up when it arrived.
        var next = detail
        next.overrideHash = nil
        next.overrideIsUnreadable = false
        state.entityDetail = next
        if kind == .artist {
            approximateData = nil
            recomputeImage()
            startArtistImageIfNeeded(detail.request, token: generation)
        } else {
            maybeStartServiceImage()
            recomputeImage()
        }
    }

    public func beginOverride(_ request: EntityRequest) {
        state.imageOverrideDraft = ImageOverrideDraft(request: request)
        state.imageOverrideError = nil
    }

    public func clearOverrideDraft() {
        state.imageOverrideDraft = nil
        state.imageOverrideError = nil
    }

    private func applySucceeded(override: ImageOverride, data: Data) {
        imageTask?.cancel()
        imageTask = nil
        state.artworkByHash[override.artworkHash] = data
        guard let detail = state.entityDetail,
              detail.request.kind == override.kind,
              detail.request.key == override.key
        else { return }
        overridePresent = true
        overrideData = data
        approximateData = nil
        var next = detail
        next.overrideHash = override.artworkHash
        next.overrideIsUnreadable = false
        state.entityDetail = next
        recomputeImage()
    }

    // MARK: - Artwork resolution

    private func loadOverride(for request: EntityRequest, token: Int) async {
        guard request.kind.supportsImageOverride else { return }
        guard let override = state.imageOverrides.first(where: {
            $0.kind == request.kind && $0.key == request.key
        }) else {
            overridePresent = false
            if request.kind == .artist {
                startArtistImageIfNeeded(request, token: token)
            }
            return
        }
        overridePresent = true
        if var detail = state.entityDetail {
            detail.overrideHash = override.artworkHash
            state.entityDetail = detail
        }
        let data = await artworkData(for: override.artworkHash)
        guard isCurrent(token), var current = state.entityDetail else { return }
        if let data, ArtworkNormalizer.isReadable(data) {
            overrideData = data
            current.overrideIsUnreadable = false
        } else {
            // An override that exists but cannot be read owns the outcome:
            // decision 10 says neutral, not the next source, and no Apple
            // lookup may run while the user's override is in place.
            overrideData = nil
            current.overrideIsUnreadable = true
        }
        state.entityDetail = current
        recomputeImage()
    }

    private func recomputeImage() {
        guard var detail = state.entityDetail else { return }
        if overridePresent {
            if let overrideData {
                detail.imageData = overrideData
                detail.imageSource = .override
            } else {
                detail.imageData = nil
                detail.imageSource = .neutral
            }
            state.entityDetail = detail
            return
        }
        switch detail.request.kind {
        case .artist:
            if let approximateData {
                detail.imageData = approximateData
                detail.imageSource = .approximate
            } else {
                detail.imageData = nil
                detail.imageSource = .neutral
            }
        case .album:
            if let capturedData {
                detail.imageData = capturedData
                detail.imageSource = .captured
            } else if let serviceImageData {
                detail.imageData = serviceImageData
                detail.imageSource = .service
            } else {
                detail.imageData = nil
                detail.imageSource = .neutral
            }
        case .track:
            if let capturedData {
                detail.imageData = capturedData
                detail.imageSource = .captured
            } else {
                detail.imageData = nil
                detail.imageSource = .neutral
            }
        }
        state.entityDetail = detail
    }

    private func artworkData(for hash: String) async -> Data? {
        if let known = state.artworkByHash[hash] {
            return known
        }
        guard let artworkStore, let data = try? await artworkStore.artwork(for: hash) else { return nil }
        state.artworkByHash[hash] = data
        return data
    }

    /// The detail page's rows need the same cover cache as History.
    private func loadStoredArtwork(for listens: [Listen]) async {
        guard let artworkStore else { return }
        let missing = Set(listens.compactMap(\.artworkHash))
            .filter { state.artworkByHash[$0] == nil }
        for hash in missing {
            guard let data = try? await artworkStore.artwork(for: hash) else { continue }
            guard isActive else { return }
            state.artworkByHash[hash] = data
        }
    }

    /// A page read can start before a cover is attached and finish after it.
    /// The same rule as History: a known hash from any loaded row fills a nil
    /// hash for the same raw track identity.
    private func fillingKnownArtwork(_ listens: [Listen]) -> [Listen] {
        var known: [String: String] = [:]
        for listen in state.listens + (state.entityDetail?.track?.listens ?? []) {
            guard let hash = listen.artworkHash else { continue }
            if known[listen.raw.identity] == nil {
                known[listen.raw.identity] = hash
            }
        }
        guard !known.isEmpty else { return listens }
        return listens.map { listen in
            guard listen.artworkHash == nil,
                  let hash = known[listen.raw.identity]
            else { return listen }
            return listen.withArtworkHash(hash)
        }
    }

    // MARK: - Helpers

    private func isCurrent(_ token: Int) -> Bool {
        isActive && token == generation && !Task.isCancelled
    }

    private func nextLoadSequence() -> Int {
        loadMoreSequence += 1
        return loadMoreSequence
    }

    private func cancelAll() {
        localTask?.cancel()
        localTask = nil
        serviceTask?.cancel()
        serviceTask = nil
        imageTask?.cancel()
        imageTask = nil
        serviceImageTask?.cancel()
        serviceImageTask = nil
    }

    private func clearCandidates() {
        overridePresent = false
        overrideData = nil
        approximateData = nil
        capturedData = nil
        serviceImageData = nil
    }

    private static func normalized(_ data: Data) async -> StoredArtwork? {
        await Task.detached(priority: .userInitiated) {
            ArtworkNormalizer.normalize(data)
        }.value
    }

    private static func connectionKey(_ connection: Connection?) -> String {
        guard let connection else { return "none" }
        return [
            String(connection.id ?? -1),
            connection.kind.rawValue,
            connection.endpoint.description,
            connection.identity,
            connection.authState.rawValue,
        ].joined(separator: "\u{1F}")
    }

    // MARK: - Timeout race

    private enum ServiceRead: Sendable {
        case facts(EntityServiceFacts)
        case missing
        case failure(EntityServiceFailure)
    }

    private enum ServiceImageRead: Sendable {
        case image(Data)
        case failure
    }

    private enum ArtistImageRead: Sendable {
        case image(Data)
        case miss
        case failure
    }

    private nonisolated static func timed<Value: Sendable>(
        seconds: TimeInterval,
        _ operation: @escaping @Sendable () async -> Value,
    ) async -> EntityTimedResult<Value> {
        let race = EntityTimeoutRace<Value>()
        let work = Task {
            let value = await operation()
            await race.finish(.value(value))
        }
        let timer = Task {
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            await race.finish(.timedOut)
        }
        let first = await race.wait()
        work.cancel()
        timer.cancel()
        return first
    }
}

private enum EntityTimedResult<Value: Sendable>: Sendable {
    case value(Value)
    case timedOut
    case cancelled
}

/// A one-shot race. The winner returns without waiting for a request that
/// ignores cancellation.
private actor EntityTimeoutRace<Value: Sendable> {
    private var result: EntityTimedResult<Value>?
    private var waiter: CheckedContinuation<EntityTimedResult<Value>, Never>?

    func finish(_ value: EntityTimedResult<Value>) {
        guard result == nil else { return }
        result = value
        waiter?.resume(returning: value)
        waiter = nil
    }

    func wait() async -> EntityTimedResult<Value> {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let result {
                    continuation.resume(returning: result)
                } else {
                    waiter = continuation
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.finish(.cancelled)
            }
        }
    }
}

public enum ImageOverrideError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedKind
    case tooLarge
    case unreadable
    case noSelection

    public var errorDescription: String? {
        switch self {
        case .unsupportedKind:
            "Only an artist or album image can be chosen."
        case .tooLarge:
            "That image is too large. Choose one smaller than 20 MB."
        case .unreadable:
            "That image could not be read. The page keeps its neutral sleeve until you choose another."
        case .noSelection:
            "Choose an artist or album before choosing an image."
        }
    }
}
