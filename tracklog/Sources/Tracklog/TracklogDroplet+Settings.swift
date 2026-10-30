import DroppyKit
import SwiftUI
import TracklogCore

// MARK: - Settings

extension TracklogDroplet: SettingsPagesProviding {
    public func makeSettingsPane(context _: SettingsPaneContext) -> AnyView {
        if host?.environment.isHarness == true {
            return AnyView(TracklogHarnessSettingsPane(droplet: self, state: state))
        }
        return AnyView(TracklogSettings(droplet: self, state: state))
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

/// Harness-only preview host for nested Settings pages. It installs the public
/// page opener so `DropletSettingsPageLink` exercises the same
/// `makeSettingsPage` route the real host uses. Production never reaches it.
private struct TracklogHarnessSettingsPane: View {
    let droplet: TracklogDroplet
    @ObservedObject var state: TracklogAppState

    var body: some View {
        Group {
            if let id = state.harnessSettingsPage,
               id != tracklogRootPageID,
               let page = droplet.makeSettingsPage(
                   id: id,
                   context: SettingsPaneContext(presentation: .harness),
               ) {
                page
            } else {
                TracklogSettings(droplet: droplet, state: state)
            }
        }
        .environment(
            \.dropletSettingsPageOpener,
            DropletSettingsPageOpener { id, _ in
                state.setHarnessSettingsPage(id)
            },
        )
    }
}
