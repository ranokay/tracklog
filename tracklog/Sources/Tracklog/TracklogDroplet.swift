import AppKit
import Combine
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
public final class TracklogDroplet: NSObject, ObservableObject, Droplet {
    /// Must equal `DroppyDropletID` in the bundle's Info.plist and `id` in
    /// droplet.json. The loader refuses the bundle if the three disagree.
    public nonisolated static let id: DropletID = "tracklog"

    @Published public private(set) var scrobblingEnabled = false
    @Published public private(set) var nowPlaying: MediaSample?
    @Published public private(set) var status: ScrobbleStatus = .idle
    @Published public private(set) var helperAvailable = true
    @Published public private(set) var scrobbleCount = 0
    @Published public private(set) var lastScrobble: Scrobble?

    private var host: DropletHost?
    private let engine = ScrobbleEngine()
    private var feed: MediaHelperFeed?

    public func activate(host: DropletHost) throws {
        self.host = host
        scrobblingEnabled = host.preferences.value(forKey: "scrobblingEnabled", default: false)
        helperAvailable = MediaHelperFeed().isAvailable
        if scrobblingEnabled {
            startFeed()
        }
        host.log.info("Tracklog activated")
    }

    public func deactivate() {
        stopFeed()
        engine.reset()
        host = nil
    }

    // MARK: - Scrobbling

    public var scrobblingBinding: Binding<Bool> {
        Binding(
            get: { self.scrobblingEnabled },
            set: { self.setScrobblingEnabled($0) },
        )
    }

    public func setScrobblingEnabled(_ enabled: Bool) {
        guard enabled != scrobblingEnabled else { return }
        scrobblingEnabled = enabled
        host?.preferences.setValue(enabled, forKey: "scrobblingEnabled")
        if enabled {
            startFeed()
        } else {
            stopFeed()
            engine.reset()
        }
    }

    private func startFeed() {
        guard feed == nil else { return }
        let feed = MediaHelperFeed()
        self.feed = feed
        helperAvailable = feed.isAvailable
        if feed.isAvailable == false {
            host?.log.notice("Droppy media helper unavailable; now playing cannot be read")
        }
        feed.start { [weak self] sample in
            self?.handle(sample)
        }
    }

    private func stopFeed() {
        feed?.stop()
        feed = nil
        nowPlaying = nil
        status = .idle
    }

    private func handle(_ sample: MediaSample?) {
        nowPlaying = sample
        let effects = engine.ingest(sample)
        status = engine.status

        for effect in effects {
            switch effect {
            case let .nowPlaying(track):
                host?.log.info("Now playing: \(track.artist) — \(track.title)")
            case let .scrobble(scrobble):
                scrobbleCount += 1
                lastScrobble = scrobble
                // The local queue and the service clients land here next.
                host?.log.info("Scrobbled: \(scrobble.track.artist) — \(scrobble.track.title)")
            }
        }
    }

    // MARK: - Presentation

    public func openSettings() {
        host?.workspace.openSettings()
    }

    /// The player's display name, for the widget's status line.
    public var sourceName: String? {
        guard let bundleID = nowPlaying?.track.bundleID, !bundleID.isEmpty else { return nil }
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
        AnyView(TracklogWidget(droplet: self, context: context))
    }

    public func makeWidgetSettingsPopover(_: ShelfWidgetID) -> AnyView? {
        nil
    }
}

// MARK: - Settings

extension TracklogDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context _: SettingsPaneContext) -> AnyView {
        AnyView(TracklogSettings(droplet: self))
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
