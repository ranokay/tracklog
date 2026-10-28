import DroppyKit
import SwiftUI

// MARK: - Settings

extension TracklogDroplet: SettingsPagesProviding {
    public func makeSettingsPane(context _: SettingsPaneContext) -> AnyView {
        AnyView(TracklogSettings(droplet: self, state: state))
    }

    public func makeSettingsPage(id: String, context _: SettingsPaneContext) -> AnyView? {
        switch id {
        case tracklogAppsPageID:
            AnyView(TracklogAppsPage(droplet: self, state: state))
        case tracklogEditsPageID:
            AnyView(TracklogEditsPage(droplet: self, state: state))
        case tracklogBlocksPageID:
            AnyView(TracklogBlocksPage(droplet: self, state: state))
        case tracklogServicesPageID:
            AnyView(TracklogServicesPage(droplet: self, state: state))
        case tracklogAddServicePageID:
            AnyView(TracklogAddServicePage(droplet: self, state: state))
        default:
            if let connectionID = tracklogConnectionID(fromPage: id) {
                AnyView(
                    TracklogConnectionPage(
                        droplet: self,
                        state: state,
                        connectionID: connectionID,
                    ),
                )
            } else {
                nil
            }
        }
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
                title: "Edits",
                keywords: ["edits", "metadata", "title", "artist", "album", "fix"],
            ),
            SettingsSearchEntry(
                title: "Blocks",
                keywords: ["blocks", "blocked", "hide", "podcast", "artist", "album"],
            ),
            SettingsSearchEntry(
                title: "Services",
                keywords: ["last.fm", "listenbrainz", "libre.fm"],
            ),
        ]
    }
}
