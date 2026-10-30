import AppKit
import DroppyKit
import SwiftUI
import TracklogCore
import TracklogMedia

/// The class Droppy's loader instantiates, named in the bundle's
/// `NSPrincipalClass`. Keep it empty: it runs before the host is ready.
@objc(TracklogPrincipal)
public final class TracklogPrincipal: NSObject, DropletPrincipal {
    override public init() {
        super.init()
    }

    @MainActor public func makeDroplet() -> AnyObject {
        TracklogDroplet()
    }
}

/// Tracklog.
@MainActor
public final class TracklogDroplet: NSObject, Droplet {
    /// Must equal `DroppyDropletID` in the bundle's Info.plist and `id` in
    /// droplet.json. The loader refuses the bundle if the three disagree.
    public nonisolated static let id: DropletID = "tracklog"

    /// The one observable state every surface reads.
    public let state = TracklogAppState()

    var host: DropletHost?
    var runtime: CaptureRuntime?
    /// The Last.fm browser link's page model. It lives here, not in the view,
    /// because Droppy rebuilds the page view each time it opens and the pending
    /// token must survive that.
    var lastFMLink: LastFMLinkModel?
    /// The browser re-auth in flight, bound to the connection page that
    /// started it. The model survives a page rebuild while that page stays
    /// open, the same way a first link does.
    var reauthLink: TracklogReauthLink?
    /// The transport the production runtime and its link models share.
    var serviceTransport: URLSessionTransport?
    /// The Libre.fm browser link in flight, with the root it was started
    /// against. Kept in the droplet for the same reason as Last.fm's model.
    var libreFMLink: TracklogLibreFMLink?
    /// The one Libre.fm adapter. The link flow needs it after activation and
    /// each delivery builds its client from the connection's own root.
    var libreFMAdapter: LibreFMAdapter?
    /// Tracklog's own HUD slot. The session tracks the active id so a newer
    /// event replaces it before the host's priority bands decide, and the
    /// announcement fires only after the host accepts the presentation.
    var hudSession: HUDHostSession?

    /// Whether the droplet can start a Libre.fm link at all. The harness has
    /// no transport, so its pages say so instead of offering a dead button.
    var canLinkLibreFM: Bool {
        libreFMAdapter != nil
    }

    /// The effective Last.fm pair source shared by the link and the runtime.
    /// It holds no pair itself, only the credential store it reads.
    var lastFMAppCredentialsProvider: StoredLastFMAppCredentials?
    var automationGate: HostAutomationPermissionGate?
    var networkReachability: NetworkReachability?
    var activationTask: Task<Void, Never>?
    /// The export is owned by this activation. A deactivation cancels it and
    /// closes any save panel it opened.
    var exportTask: Task<Void, Never>?
    var exportOperationID: UUID?
    var exportPanel: NSSavePanel?
    var exportAlert: NSAlert?

    public func activate(host: DropletHost) throws {
        self.host = host

        let isHarness = host.environment.isHarness
        let hudSession = HUDHostSession(
            host: TracklogHUDHost(droplet: self),
            announce: { presentation in
                TracklogAccessibilityAnnouncer.post(presentation)
            },
            logRefusal: { presentation in
                host.log.debug("HUD \(presentation.id) was refused")
            },
        )
        self.hudSession = hudSession
        let transport: URLSessionTransport?
        let runtime: CaptureRuntime
        if isHarness {
            transport = nil
            runtime = makeHarnessRuntime(hud: hudSession)
        } else {
            let sessionTransport = URLSessionTransport()
            transport = sessionTransport
            let libreFM = LibreFMAdapter(transport: sessionTransport)
            libreFMAdapter = libreFM
            runtime = makeProductionRuntime(
                host: host,
                transport: sessionTransport,
                credentials: KeychainCredentialStore(),
                libreFM: libreFM,
                hud: hudSession,
            )
        }
        self.runtime = runtime
        if isHarness {
            state.setHarnessSettingsPage(
                ProcessInfo.processInfo.environment["TRACKLOG_HARNESS_SETTINGS_PAGE"],
            )
        }
        if let transport, let lastFMAppCredentialsProvider {
            lastFMLink = makeLastFMLink(
                transport: transport,
                appCredentials: lastFMAppCredentialsProvider,
            )
        }
        serviceTransport = transport
        if !isHarness {
            let reachability = NetworkReachability { [weak runtime] in
                runtime?.networkBecameAvailable()
            }
            networkReachability = reachability
            reachability.start()
        }

        if let failure = runtime.state.failure {
            host.log.notice(failure.diagnostics)
        }
        let mediaStatus = runtime.state.mediaStatus
        if !mediaStatus.isAvailable {
            host.log.notice("No media source can read now playing: \(mediaStatus.helperHealth.summary)")
        }
        activationTask = Task {
            await runtime.start()
            if isHarness {
                await HarnessDemo.showNowPlaying(on: runtime)
                // The HUD page renders nothing until the droplet presents, so
                // the shot needs one deterministic card. It goes through the
                // same host session and announcement path as a real event.
                hudSession.show(
                    HUD.resolve(.needsSignIn(services: ["Last.fm"])),
                )
            }
        }
        host.log.info("Tracklog activated")
    }

    // MARK: - Scrobbling

    public var scrobblingBinding: Binding<Bool> {
        Binding(
            get: { self.state.scrobblingEnabled },
            set: { self.setScrobblingEnabled($0) },
        )
    }

    public func setScrobblingEnabled(_ enabled: Bool) {
        runtime?.setScrobblingEnabled(enabled)
    }

    public var nowPlayingBinding: Binding<Bool> {
        Binding(
            get: { self.state.nowPlayingEnabled },
            set: { self.setNowPlayingEnabled($0) },
        )
    }

    public func setNowPlayingEnabled(_ enabled: Bool) {
        runtime?.setNowPlayingEnabled(enabled)
    }

    public var minimumDurationBinding: Binding<Double> {
        Binding(
            get: { self.state.minimumDuration },
            set: { self.setMinimumDuration($0) },
        )
    }

    public func setMinimumDuration(_ seconds: TimeInterval) {
        runtime?.setMinimumDuration(seconds)
    }

    // MARK: - Pause

    public func pauseCapture(for duration: TimeInterval) {
        runtime?.pause(for: duration)
    }

    public func pauseCapture(until date: Date) {
        runtime?.pause(until: date)
    }

    public func resumeCapture() {
        runtime?.resume()
    }

    // MARK: - The listen in flight

    func cancelCurrentListen() {
        runtime?.cancelCurrentListen()
    }

    func undoCancelCurrentListen() {
        runtime?.undoCancelCurrentListen()
    }

    /// Opens the Edits page with a new rule pre-filled from the current
    /// track's fields as the metadata pipeline matches them.
    func editCurrentListen() {
        guard let runtime, let match = runtime.editMatchForCurrentListen() else { return }
        state.requestEditPrefill(match)
        guard openSettingsPage(tracklogEditsPageID, title: "Edits") else {
            // Discard the request so a refused open does not surface a draft
            // the next time the user visits Edits by hand.
            _ = state.takeEditPrefill()
            host?.log.notice("Opening the Edits page was refused")
            return
        }
    }

    // MARK: - Players

    public func setAppAllowed(_ bundleID: String, allowed: Bool) {
        Task { await runtime?.setAppAllowed(bundleID, allowed: allowed) }
    }

    /// The player's name for the Apps page: the running app's, its bundle
    /// name, the seeded name when it is no longer installed, or the
    /// identifier itself.
    public func appName(for bundleID: String) -> String {
        if let name = displayName(for: bundleID) {
            return name
        }
        if let name = Self.seededPlayerNames[bundleID] {
            return name
        }
        return bundleID
    }

    func displayName(for bundleID: String) -> String? {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = app.localizedName, !name.isEmpty {
            return name
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let name = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String,
              !name.isEmpty
        else { return nil }
        return name
    }

    private static let seededPlayerNames = [
        "com.apple.Music": "Music",
        "com.spotify.client": "Spotify",
    ]

    // MARK: - Presentation

    public func openSettings() {
        dismissTakeoverForSettings()
        host?.workspace.openSettings()
    }

    /// Opens one of the droplet's own Settings pages. Any History takeover is
    /// dismissed first: Settings is the only typed surface, and it must not
    /// sit underneath the takeover.
    @discardableResult
    func openSettingsPage(_ id: String, title: String) -> Bool {
        dismissTakeoverForSettings()
        guard let host else { return false }
        return host.workspace.openSettingsPage(id, title: title)
    }

    public func presentHistory(expandingPending: Bool = false) {
        guard let host else { return }
        if expandingPending {
            state.setPendingListExpanded(true)
        }
        host.notchSurface.presentExpandedSurface(
            ExpandedSurfacePresentationRequest(surfaceID: tracklogHistorySurfaceID),
        )
    }

    // MARK: - History

    func reloadHistory() async {
        await runtime?.reloadHistory()
    }

    func loadMoreHistory() async {
        await runtime?.loadMoreHistory()
    }

    func artworkData(for listen: Listen) -> Data? {
        guard let hash = listen.artworkHash else { return nil }
        return state.artworkByHash[hash]
    }

    func copyMetadata(for listen: Listen) {
        guard let host else { return }
        if !host.workspace.copyToPasteboard(listen.processed.copyText) {
            host.log.notice("Copy metadata was refused")
        }
    }

    // MARK: - Media

    func copyMediaDiagnostics() {
        guard let host else { return }
        let text = MediaDiagnostics.text(
            status: state.mediaStatus,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            droppyVersion: host.environment.appVersion,
        )
        if !host.workspace.copyToPasteboard(text) {
            host.log.notice("Copy diagnostics was refused")
        }
    }

    func openAutomationSettings() {
        automationGate?.forgetDenial()
        host?.permissions.openSystemSettings(for: .appleEvents)
    }

    // MARK: - Edits

    func saveSimpleEdit(_ rule: SimpleEditRule) async throws {
        guard let runtime else { throw DatabaseError.unavailable("Tracklog is not active") }
        try await runtime.saveSimpleEdit(rule)
    }

    func deleteSimpleEdit(id: Int64) async throws {
        guard let runtime else { throw DatabaseError.unavailable("Tracklog is not active") }
        try await runtime.deleteSimpleEdit(id: id)
    }

    // MARK: - Blocks

    func saveBlock(_ block: BlockRule) async throws {
        guard let runtime else { throw DatabaseError.unavailable("Tracklog is not active") }
        try await runtime.saveBlock(block)
    }

    func deleteBlock(id: Int64) async throws {
        guard let runtime else { throw DatabaseError.unavailable("Tracklog is not active") }
        try await runtime.deleteBlock(id: id)
    }
}
