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
            runtime = CaptureRuntime(
                state: state,
                clock: SystemClock(),
                source: HarnessDemoSource(),
                store: HarnessDemoStore(),
                scrobblingEnabled: true,
            )
        } else {
            let enabled = host.preferences.value(forKey: "scrobblingEnabled", default: false)
            let databaseURL = host.environment.containerDirectory.appendingPathComponent("tracklog.sqlite")
            runtime = CaptureRuntime.open(
                state: state,
                databaseURL: databaseURL,
                clock: SystemClock(),
                source: MediaHelperFeed(),
                scrobblingEnabled: enabled,
                persistScrobbling: { enabled in
                    host.preferences.setValue(enabled, forKey: "scrobblingEnabled")
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
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = app.localizedName {
            return name
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String
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

extension TracklogDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context _: SettingsPaneContext) -> AnyView {
        AnyView(TracklogSettings(droplet: self, state: state))
    }

    public var settingsSearchEntries: [SettingsSearchEntry] {
        [
            SettingsSearchEntry(
                title: "Scrobble what I play",
                keywords: ["scrobble", "play", "now playing"],
            ),
            SettingsSearchEntry(
                title: "Services",
                keywords: ["last.fm", "listenbrainz", "libre.fm", "pleroma"],
            ),
        ]
    }
}
