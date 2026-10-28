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

    private(set) var host: DropletHost?
    private(set) var runtime: CaptureRuntime?
    /// The Last.fm browser link's page model. It lives here, not in the view,
    /// because Droppy rebuilds the page view each time it opens and the pending
    /// token must survive that.
    private(set) var lastFMLink: LastFMLinkModel?
    var automationGate: HostAutomationPermissionGate?
    private var networkReachability: NetworkReachability?
    private var activationTask: Task<Void, Never>?

    public func activate(host: DropletHost) throws {
        self.host = host

        let isHarness = host.environment.isHarness
        let transport: URLSessionTransport?
        let runtime: CaptureRuntime
        if isHarness {
            transport = nil
            runtime = makeHarnessRuntime()
        } else {
            let sessionTransport = URLSessionTransport()
            transport = sessionTransport
            runtime = makeProductionRuntime(host: host, transport: sessionTransport)
        }
        self.runtime = runtime
        if let transport {
            lastFMLink = makeLastFMLink(transport: transport)
        }
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
            }
        }
        host.log.info("Tracklog activated")
    }

    public func deactivate() {
        activationTask?.cancel()
        activationTask = nil
        lastFMLink?.cancel()
        lastFMLink = nil
        networkReachability?.stop()
        networkReachability = nil
        runtime?.stop()
        runtime = nil
        automationGate = nil
        host = nil
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
        guard host?.workspace.openSettingsPage(tracklogEditsPageID, title: "Edits") == true else {
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

    private func displayName(for bundleID: String) -> String? {
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
        host?.workspace.openSettings()
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

    /// The player's display name, for the widget's status line.
    public var sourceName: String? {
        guard let bundleID = state.nowPlaying?.track.bundleID, !bundleID.isEmpty else { return nil }
        return displayName(for: bundleID)
    }
}

// MARK: - Shelf widget

extension TracklogDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [
            ShelfWidgetDescriptor(
                id: "tracklog",
                title: "Tracklog",
                systemImage: "waveform",
                layoutTraits: ShelfWidgetLayoutTraits(
                    preferredSoloWidth: 420,
                    preferredPairedWidth: 210,
                    contentHeight: .fixed(150),
                ),
            ),
        ]
    }

    public func makeWidgetView(_: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(TracklogWidget(droplet: self, state: state, context: context))
    }

    public func makeWidgetSettingsPopover(_: ShelfWidgetID) -> AnyView? {
        nil
    }
}
