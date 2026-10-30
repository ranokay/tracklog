import DroppyKit
import SwiftUI

// MARK: - Settings

extension TracklogDroplet: SettingsPagesProviding {
    public func makeSettingsPane(context _: SettingsPaneContext) -> AnyView {
        // The harness cannot follow a page link because it installs no page
        // opener. An environment override lets the runtime checks mount one
        // nested page in the pane without changing production behavior.
        if let page = harnessSettingsPageOverride {
            switch page {
            case tracklogDataPageID:
                return AnyView(TracklogDataPage(droplet: self, state: state))
            case tracklogAboutPageID:
                return AnyView(TracklogAboutPage(droplet: self))
            case tracklogAppsPageID:
                return AnyView(TracklogAppsPage(droplet: self, state: state))
            case tracklogServicesPageID:
                return AnyView(TracklogServicesPage(droplet: self, state: state))
            case tracklogEditsPageID:
                return AnyView(TracklogEditsPage(droplet: self, state: state))
            case tracklogBlocksPageID:
                return AnyView(TracklogBlocksPage(droplet: self, state: state))
            default:
                break
            }
        }
        return AnyView(TracklogSettings(droplet: self, state: state))
    }

    private var harnessSettingsPageOverride: String? {
        guard host?.environment.isHarness == true else { return nil }
        return ProcessInfo.processInfo.environment["TRACKLOG_HARNESS_SETTINGS_PAGE"]
    }

    public func makeSettingsPage(id: String, context _: SettingsPaneContext) -> AnyView? {
        if let page = primaryPage(id) {
            return page
        }
        if let page = servicePage(id) {
            return page
        }
        guard let connectionID = tracklogConnectionID(fromPage: id) else {
            return nil
        }
        return AnyView(
            TracklogConnectionPage(
                droplet: self,
                state: state,
                connectionID: connectionID,
            ),
        )
    }

    private func primaryPage(_ id: String) -> AnyView? {
        switch id {
        case tracklogRootPageID:
            AnyView(TracklogSettings(droplet: self, state: state))
        case tracklogAppsPageID:
            AnyView(TracklogAppsPage(droplet: self, state: state))
        case tracklogEditsPageID:
            AnyView(TracklogEditsPage(droplet: self, state: state))
        case tracklogBlocksPageID:
            AnyView(TracklogBlocksPage(droplet: self, state: state))
        case tracklogDataPageID:
            AnyView(TracklogDataPage(droplet: self, state: state))
        case tracklogAboutPageID:
            AnyView(TracklogAboutPage(droplet: self))
        default:
            nil
        }
    }

    private func servicePage(_ id: String) -> AnyView? {
        switch id {
        case tracklogServicesPageID:
            AnyView(TracklogServicesPage(droplet: self, state: state))
        case tracklogAddServicePageID:
            AnyView(TracklogAddServicePage(droplet: self, state: state))
        case tracklogLastFMLinkPageID:
            AnyView(TracklogLastFMLinkPage(droplet: self, state: state))
        case tracklogLibreFMLinkPageID:
            AnyView(TracklogLibreFMLinkPage(droplet: self, state: state))
        case tracklogLastFMAppCredentialsPageID:
            AnyView(TracklogLastFMAppCredentialsPage(droplet: self, state: state))
        default:
            nil
        }
    }

    /// One entry per page, in the order the root links them. The host opens
    /// the droplet's pane; the root's links take it from there.
    public var settingsSearchEntries: [SettingsSearchEntry] {
        [
            SettingsSearchEntry(
                title: "Scrobbling",
                keywords: ["capture", "pause", "now playing", "minimum length", "scrobble"],
                anchorID: tracklogRootPageID,
            ),
            SettingsSearchEntry(
                title: "Services",
                keywords: ["last.fm", "listenbrainz", "libre.fm", "account", "connect"],
                anchorID: tracklogServicesPageID,
            ),
            SettingsSearchEntry(
                title: "Edits",
                keywords: ["metadata", "title", "artist", "album", "fix", "rule"],
                anchorID: tracklogEditsPageID,
            ),
            SettingsSearchEntry(
                title: "Blocks",
                keywords: ["blocked", "hide", "podcast", "artist", "album", "wildcard"],
                anchorID: tracklogBlocksPageID,
            ),
            SettingsSearchEntry(
                title: "Data",
                keywords: ["export", "diagnostics", "media source", "database", "json"],
                anchorID: tracklogDataPageID,
            ),
            SettingsSearchEntry(
                title: "About",
                keywords: ["version", "licence", "credits", "pano", "droppy"],
                anchorID: tracklogAboutPageID,
            ),
        ]
    }
}
