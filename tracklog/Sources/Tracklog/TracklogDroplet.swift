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

    private var host: DropletHost?
    private var runtime: CaptureRuntime?
    private var activationTask: Task<Void, Never>?

    public func activate(host: DropletHost) throws {
        self.host = host

        let isHarness = host.environment.isHarness
        let runtime: CaptureRuntime
        if isHarness {
            let store = HarnessDemoStore()
            runtime = CaptureRuntime(
                state: state,
                clock: SystemClock(),
                source: HarnessDemoSource(),
                store: store,
                allowlist: store,
                settings: CaptureSettings(scrobblingEnabled: true),
            )
        } else {
            let settings = CaptureSettings(
                scrobblingEnabled: host.preferences.value(forKey: "scrobblingEnabled", default: false),
                nowPlayingEnabled: host.preferences.value(forKey: "nowPlayingEnabled", default: true),
                pausedUntil: host.preferences.value(forKey: "pausedUntil", as: Date.self),
                minimumDuration: host.preferences.value(
                    forKey: "minimumDuration",
                    default: CaptureSettings.defaultMinimumDuration,
                ),
            )
            let databaseURL = host.environment.containerDirectory.appendingPathComponent("tracklog.sqlite")
            runtime = CaptureRuntime.open(
                state: state,
                databaseURL: databaseURL,
                clock: SystemClock(),
                source: MediaHelperFeed(),
                settings: settings,
                // The delivery outbox (#39) supplies the now-playing sender;
                // the toggle persists and the gate is ready for it.
                persistSettings: { settings in
                    host.preferences.setValue(settings.scrobblingEnabled, forKey: "scrobblingEnabled")
                    host.preferences.setValue(settings.nowPlayingEnabled, forKey: "nowPlayingEnabled")
                    host.preferences.setValue(settings.pausedUntil, forKey: "pausedUntil")
                    host.preferences.setValue(settings.minimumDuration, forKey: "minimumDuration")
                },
            )
        }
        self.runtime = runtime

        if let failure = runtime.state.failure {
            host.log.notice(failure.diagnostics)
        }
        if !runtime.state.feedAvailable {
            host.log.notice("Droppy media helper unavailable; now playing cannot be read")
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
        runtime?.stop()
        runtime = nil
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

    public func presentHistory() {
        guard let host else { return }
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

    func copyMetadata(for listen: Listen) {
        guard let host else { return }
        if !host.workspace.copyToPasteboard(listen.processed.copyText) {
            host.log.notice("Copy metadata was refused")
        }
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

// MARK: - Settings

extension TracklogDroplet: SettingsPagesProviding {
    public func makeSettingsPane(context _: SettingsPaneContext) -> AnyView {
        AnyView(TracklogSettings(droplet: self, state: state))
    }

    public func makeSettingsPage(id: String, context _: SettingsPaneContext) -> AnyView? {
        guard id == tracklogAppsPageID else { return nil }
        return AnyView(TracklogAppsPage(droplet: self, state: state))
    }

    public var settingsSearchEntries: [SettingsSearchEntry] {
        [
            SettingsSearchEntry(
                title: "Scrobble what I play",
                keywords: ["scrobble", "capture", "play"],
            ),
            SettingsSearchEntry(
                title: "Pause",
                keywords: ["pause", "resume", "hold"],
            ),
            SettingsSearchEntry(
                title: "Send now playing",
                keywords: ["now playing", "profile"],
            ),
            SettingsSearchEntry(
                title: "Minimum length",
                keywords: ["minimum", "duration", "jingle", "snippet"],
            ),
            SettingsSearchEntry(
                title: "Apps",
                keywords: ["apps", "players", "allow", "deny"],
            ),
            SettingsSearchEntry(
                title: "Services",
                keywords: ["last.fm", "listenbrainz", "libre.fm", "pleroma"],
            ),
        ]
    }
}
